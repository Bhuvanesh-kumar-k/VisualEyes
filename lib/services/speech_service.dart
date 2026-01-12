import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:vosk_flutter_2/vosk_flutter_2.dart' as vosk;

typedef SpeechResultCallback = void Function(String text);

class SpeechService {
  final FlutterTts _tts = FlutterTts();

  final vosk.VoskFlutterPlugin _vosk = vosk.VoskFlutterPlugin.instance();
  final vosk.ModelLoader _modelLoader = vosk.ModelLoader();

  vosk.SpeechService? _speechService;
  vosk.Recognizer? _recognizer;

  bool _isListening = false;
  bool _initialized = false;

  StreamSubscription<String>? _resultSub;
  StreamSubscription<String>? _partialSub;

  Future<void> init({String? languageCode}) async {
    if (languageCode != null) {
      await _tts.setLanguage(languageCode);
    }
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);

    if (_initialized) {
      return;
    }

    String? modelPath;

    try {
      // Use the smaller offline model for faster startup on first launch.
      modelPath = await _modelLoader.loadFromAssets(
        'assets/models/vosk-model-small-en-us-0.15.zip',
      );
    } catch (_) {
      modelPath = null;
    }

    if (modelPath == null) {
      throw StateError('Vosk model could not be loaded from assets.');
    }

    final model = await _vosk.createModel(modelPath);
    _recognizer = await _vosk.createRecognizer(
      model: model,
      sampleRate: 16000,
    );
    _speechService = await _vosk.initSpeechService(_recognizer!);
    _initialized = true;
  }

  Future<void> setLanguage(String languageCode) async {
    await _tts.setLanguage(languageCode);
  }

  Future<void> speak(String text) async {
    if (text.isEmpty) {
      return;
    }
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  Future<void> startListening(
    SpeechResultCallback onResult, {
    String? localeId,
    Duration? listenFor,
  }) async {
    final service = _speechService;
    if (service == null || _isListening) {
      return;
    }
    _isListening = true;

    await _resultSub?.cancel();
    await _partialSub?.cancel();

    _resultSub = service.onResult().listen((text) {
      if (!_isListening) {
        return;
      }
      _isListening = false;
      onResult(text);
    });

    _partialSub = service.onPartial().listen((_) {});

    await service.start();

    if (listenFor != null) {
      Future.delayed(listenFor, () async {
        if (_isListening) {
          await stopListening();
        }
      });
    }
  }

  Future<void> stopListening() async {
    final service = _speechService;
    if (!_isListening || service == null) {
      return;
    }
    _isListening = false;
    await service.stop();
    await _resultSub?.cancel();
    await _partialSub?.cancel();
    _resultSub = null;
    _partialSub = null;
  }
}
