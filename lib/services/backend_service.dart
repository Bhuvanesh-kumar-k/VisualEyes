import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:google_generative_ai/google_generative_ai.dart' as genai;

import '../config.dart';

class _LastObjectInfo {
  final String label;
  final String position;
  final String distance;
  final String relativeSize;
  final String usage;

  const _LastObjectInfo({
    required this.label,
    required this.position,
    required this.distance,
    required this.relativeSize,
    required this.usage,
  });
}

class BackendService {
  BackendService();

  DateTime? _lastGeminiCall;
  String? _lastGeminiError;
  _LastObjectInfo? _lastMainObject;

  Future<String> analyzeImage(
    String imagePath,
    String languageCode, {
    bool useGemini = false,
  }) async {
    // Clear the last cached object description at the start of each call.
    _lastMainObject = null;
    // Prefer Gemini 2.0 Flash when explicitly requested and an API key is set.
    if (useGemini && AppConfig.geminiApiKey.isNotEmpty) {
      _lastGeminiError = null;
      final viaGemini = await _analyzeImageWithGemini(imagePath, languageCode);
      if (viaGemini.isNotEmpty) {
        // Debug: indicate that Gemini vision produced this description.
        // This will appear in `flutter run` / logcat output.
        // It is not spoken to the user.
        // ignore: avoid_print
        print('BackendService.analyzeImage: using Gemini vision');
        return viaGemini;
      }
      // ignore: avoid_print
      print('BackendService.analyzeImage: Gemini returned empty, falling back to ML Kit.');
    }

    // Fallback: on-device ML Kit object detection.
    final file = File(imagePath);
    if (!await file.exists()) {
      return '';
    }

    final bytes = await file.readAsBytes();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;
    final width = image.width;
    final height = image.height;

    final inputImage = InputImage.fromFilePath(imagePath);
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    );
    final objectDetector = ObjectDetector(options: options);
    final objects = await objectDetector.processImage(inputImage);
    await objectDetector.close();

    if (objects.isEmpty) {
      return 'I do not see any clear objects ahead.';
    }

    _LastObjectInfo? mainObject;
    double bestSizeFraction = 0;
    final buffer = StringBuffer();

    for (final detectedObject in objects) {
      final rect = detectedObject.boundingBox;
      final centerX = rect.left + rect.width / 2;
      final widthFraction = rect.width / width;
      final heightFraction = rect.height / height;
      final sizeFraction = max(widthFraction, heightFraction);

      String position;
      final xFrac = centerX / width;
      if (xFrac < 0.33) {
        position = 'on your left';
      } else if (xFrac > 0.66) {
        position = 'on your right';
      } else {
        position = 'in front of you';
      }

      String distance;
      if (sizeFraction > 0.5) {
        distance = 'very close, within half a meter';
      } else if (sizeFraction > 0.3) {
        distance = 'close, around one meter away';
      } else if (sizeFraction > 0.15) {
        distance = 'a few meters away';
      } else {
        distance = 'far away';
      }

      String relativeSize;
      if (sizeFraction > 0.4) {
        relativeSize = 'large';
      } else if (sizeFraction > 0.2) {
        relativeSize = 'medium sized';
      } else {
        relativeSize = 'small';
      }

      String rawLabel = '';
      if (detectedObject.labels.isNotEmpty) {
        final best = detectedObject.labels.reduce(
          (a, b) => a.confidence >= b.confidence ? a : b,
        );
        rawLabel = best.text;
      }

      final labelForSpeech = _labelForSpeech(rawLabel);
      final usage = _usageForLabel(rawLabel.toLowerCase());

      if (sizeFraction > bestSizeFraction) {
        bestSizeFraction = sizeFraction;
        mainObject = _LastObjectInfo(
          label: labelForSpeech,
          position: position,
          distance: distance,
          relativeSize: relativeSize,
          usage: usage,
        );
      }

      buffer.writeln('I see $labelForSpeech $position, $distance.');
    }

    _lastMainObject = mainObject;
    if (mainObject == null) {
      return 'I do not see any clear objects ahead.';
    }
    return buffer.toString().trim();
  }

  String? takeLastGeminiError() {
    final error = _lastGeminiError;
    _lastGeminiError = null;
    return error;
  }

  Future<String> ocrScreen(String imagePath, String languageCode) async {
    // TODO: Replace this stub with on-device OCR (google_ml_kit text recognition).
    final file = File(imagePath);
    if (!await file.exists()) {
      return '';
    }
    final inputImage = InputImage.fromFilePath(imagePath);
    final textRecognizer = TextRecognizer(
      script: TextRecognitionScript.latin,
    );
    final recognizedText = await textRecognizer.processImage(inputImage);
    await textRecognizer.close();
    return recognizedText.text;
  }

  Future<String> transcribeAndTranslate(String languageCode, String audioPath) async {
    // TODO: Replace this stub with offline STT + Argos Translate pipeline.
    return '';
  }

  Future<bool> enrollVoice(String username, String languageCode, String audioPath) async {
    // TODO: Replace this stub with on-device speaker enrollment (TFLite/SpeechBrain).
    return true;
  }

  Future<bool> verifyVoice(String username, String audioPath) async {
    // TODO: Replace this stub with on-device speaker verification (TFLite/SpeechBrain).
    return true;
  }

  Future<String> translateWithGemini(
    String text,
    String targetLanguageCode,
  ) async {
    final apiKey = AppConfig.geminiApiKey;
    if (apiKey.isEmpty) {
      return '';
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    String targetHint;
    if (targetLanguageCode.startsWith('ta')) {
      targetHint = 'Tamil';
    } else if (targetLanguageCode.startsWith('ml')) {
      targetHint = 'Malayalam';
    } else if (targetLanguageCode.startsWith('hi')) {
      targetHint = 'Hindi';
    } else {
      targetHint = 'simple English';
    }

    try {
      final model = genai.GenerativeModel(
        model: AppConfig.geminiVisionModel,
        apiKey: apiKey,
      );

      final prompt =
          'You are assisting a blind user. Detect the language of the following sentence and translate it into $targetHint. '
          'Use short, clear sentences that sound natural when spoken aloud. '
          'Only return the translated text, without any extra explanations or labels.\n\n'
          'Sentence: "$trimmed"';

      final response = await model.generateContent([
        genai.Content.text(prompt),
      ]);

      final out = response.text ?? '';
      return out.trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> describeLastObjectUsage(String languageCode) async {
    final info = _lastMainObject;
    if (info == null) {
      return '';
    }

    // If we have a clear usage sentence from the label map (e.g., for chair,
    // door, stairs), return it directly.
    if (info.usage.isNotEmpty) {
      return info.usage;
    }

    // For unknown objects (no mapped usage), optionally consult Gemini for a
    // short usage explanation if an API key is configured.
    final apiKey = AppConfig.geminiApiKey;
    if (apiKey.isEmpty) {
      return '';
    }

    String languageHint;
    if (languageCode.startsWith('ta')) {
      languageHint = 'Answer in 1 or 2 short sentences in simple Tamil.';
    } else if (languageCode.startsWith('ml')) {
      languageHint = 'Answer in 1 or 2 short sentences in simple Malayalam.';
    } else if (languageCode.startsWith('hi')) {
      languageHint = 'Answer in 1 or 2 short sentences in simple Hindi.';
    } else {
      languageHint = 'Answer in 1 or 2 short sentences in simple English.';
    }

    try {
      final model = genai.GenerativeModel(
        model: AppConfig.geminiVisionModel,
        apiKey: apiKey,
      );
      final prompt =
          'A blind user is asking what a "${info.label}" is usually used for. '
          'Explain the typical purpose of this object. $languageHint';
      final response = await model.generateContent([
        genai.Content.text(prompt),
      ]);
      final text = response.text ?? '';
      return text.trim();
    } catch (_) {
      // On any error (network, quota, etc.), fall back to on-device path.
      return '';
    }
  }

  Future<String> describeLastObjectSize(String languageCode) async {
    final info = _lastMainObject;
    if (info == null) {
      return '';
    }

    switch (info.relativeSize) {
      case 'large':
        return 'The object looks large compared to your view.';
      case 'medium sized':
        return 'The object looks medium sized.';
      case 'small':
      default:
        return 'The object looks small compared to your view.';
    }
  }

  void dispose() {}

  String _labelForSpeech(String raw) {
    final label = raw.toLowerCase().trim();
    if (label.isEmpty) {
      return 'something';
    }

    switch (label) {
      case 'person':
        return 'a person';
      case 'chair':
        return 'a chair';
      case 'sofa':
      case 'couch':
        return 'a sofa';
      case 'table':
        return 'a table';
      case 'desk':
        return 'a desk';
      case 'door':
        return 'a door';
      case 'stairs':
      case 'staircase':
        return 'stairs';
      case 'bottle':
        return 'a bottle';
      case 'cup':
      case 'mug':
        return 'a cup';
      case 'laptop':
      case 'computer':
      case 'monitor':
        return 'a computer device';
    }

    if (label.contains('fashion')) {
      return 'a clothing item';
    }
    if (label.contains('home good')) {
      return 'a household item';
    }
    if (label.contains('appliance')) {
      return 'a home appliance';
    }
    if (label.contains('food')) {
      return 'a food item';
    }
    if (label.contains('drink') || label.contains('beverage')) {
      return 'a drink';
    }
    if (label.contains('vehicle') || label.contains('car') || label.contains('bus')) {
      return 'a vehicle';
    }
    if (label.contains('bag')) {
      return 'a bag';
    }

    return 'something';
  }

  Future<String> _analyzeImageWithGemini(
    String imagePath,
    String languageCode,
  ) async {
    final apiKey = AppConfig.geminiApiKey;
    if (apiKey.isEmpty) {
      return '';
    }

    final file = File(imagePath);
    if (!await file.exists()) {
      return '';
    }

    final now = DateTime.now();
    if (_lastGeminiCall != null &&
        now.difference(_lastGeminiCall!).inSeconds < 5) {
      // Enforce at most one Gemini request every 5 seconds
      return '';
    }
    _lastGeminiCall = now;

    try {
      final model = genai.GenerativeModel(
        model: AppConfig.geminiVisionModel,
        apiKey: apiKey,
      );

      final bytes = await file.readAsBytes();

      String languageHint;
      if (languageCode.startsWith('ta')) {
        languageHint = 'Answer in short, simple Tamil sentences.';
      } else if (languageCode.startsWith('ml')) {
        languageHint = 'Answer in short, simple Malayalam sentences.';
      } else if (languageCode.startsWith('hi')) {
        languageHint = 'Answer in short, simple Hindi sentences.';
      } else {
        languageHint = 'Answer in short, simple English sentences.';
      }

      final prompt =
          'You are assisting a blind user in real time. Carefully look at the whole scene and describe it in detail. '
          'First, describe all clearly visible people: for each person, say where they are (left, right, or center), roughly how far they are, their approximate age group (child, young adult, adult, older adult), '
          'their gender if it is obvious, their body position (standing, sitting, walking, facing the user, turned away), and their clothing: colour of top and bottom, clothing type (shirt, T-shirt, saree, trousers, jeans, shorts, dress, etc.), and any notable style or pattern. '
          'Then, describe the main objects and furniture: for each important object, say what it is, its colour, where it is (left, right, or center), roughly how far it is, and if it is large, medium, or small. '
          'Also describe important parts of the room or environment such as doors, windows, tables, chairs, sofas, shelves, TV, computer, bags, and other items the user could touch or bump into. '
          'If the scene includes an ATM, payment terminal, kiosk, touchscreen, or keypad, describe the layout (screen, card slot, keypad, buttons) and where each part is. '
          'If the scene shows a road or crossing, describe the road, any zebra crossing, traffic lights, vehicles, and their approximate movement or speed, and say clearly if it looks safe or not safe to cross. '
          'Speak in short, clear sentences that sound natural when spoken aloud. Avoid long paragraphs. $languageHint';

      final response = await model.generateContent([
        genai.Content.text(prompt),
        genai.Content.data('image/jpeg', bytes),
      ]);

      final text = response.text ?? '';
      return text.trim();
    } catch (e) {
      _lastGeminiError = e.toString();
      // On any error (network, quota, etc.), fall back to on-device path.
      return '';
    }
  }

  Future<String> answerQuestionWithGemini({
    required String question,
    required String languageCode,
    required List<String> imagePaths,
    double? latitude,
    double? longitude,
  }) async {
    final apiKey = AppConfig.geminiApiKey;
    if (apiKey.isEmpty) {
      return '';
    }

    final trimmedQuestion = question.trim();
    if (trimmedQuestion.isEmpty) {
      return '';
    }

    try {
      final model = genai.GenerativeModel(
        model: AppConfig.geminiVisionModel,
        apiKey: apiKey,
      );

      String languageHint;
      if (languageCode.startsWith('ta')) {
        languageHint = 'Answer in short, simple Tamil sentences.';
      } else if (languageCode.startsWith('ml')) {
        languageHint = 'Answer in short, simple Malayalam sentences.';
      } else if (languageCode.startsWith('hi')) {
        languageHint = 'Answer in short, simple Hindi sentences.';
      } else {
        languageHint = 'Answer in short, simple English sentences.';
      }

      final contents = <genai.Content>[];

      final buffer = StringBuffer();
      buffer.writeln(
          'You are assisting a blind user who previously received a few image descriptions.');
      buffer.writeln(
          'Use the images (if provided), the user\'s question, and general knowledge to answer clearly.');
      if (latitude != null && longitude != null) {
        buffer.writeln(
            'The user\'s approximate GPS location is: latitude $latitude, longitude $longitude.');
        buffer.writeln(
            'If the question is about distances, travel time, or nearby places, take this location into account.');
      }
      buffer.writeln(languageHint);
      buffer.writeln(
          'Always speak as if you are talking directly to the user. Avoid long paragraphs and technical details.');
      buffer.writeln('User question: "$trimmedQuestion"');

      contents.add(genai.Content.text(buffer.toString()));

      for (final path in imagePaths) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          contents.add(genai.Content.data('image/jpeg', bytes));
        }
      }

      final response = await model.generateContent(contents);
      final text = response.text ?? '';
      return text.trim();
    } catch (_) {
      return '';
    }
  }

  String _usageForLabel(String label) {
    switch (label) {
      case 'chair':
        return 'It is a chair, mainly used for sitting.';
      case 'sofa':
      case 'couch':
        return 'It is a sofa, used for sitting or lying down.';
      case 'table':
      case 'desk':
        return 'It is a table, used for placing things or working.';
      case 'door':
        return 'It is a door, used to enter or leave a room.';
      case 'stairs':
      case 'staircase':
        return 'These are stairs, used for going up or down between levels. Take extra care.';
      case 'bottle':
        return 'It looks like a bottle, usually used for holding liquids.';
      case 'cup':
      case 'mug':
        return 'It is a cup, usually used for drinking.';
      case 'laptop':
      case 'computer':
      case 'monitor':
        return 'It looks like a computer device, used for work or study.';
      default:
        return '';
    }
  }
}
