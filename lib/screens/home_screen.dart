import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/backend_service.dart';
import '../services/camera_service.dart';
import '../services/exam_mode_service.dart';
import '../services/speech_service.dart';
import '../state/app_state.dart';
import '../config.dart';

class _LogEntry {
  final bool isUser;
  final String text;
  final String time;

  const _LogEntry({
    required this.isUser,
    required this.text,
    required this.time,
  });
}

class _ImageContextEntry {
  final String imagePath;
  final String description;
  final DateTime timestamp;

  const _ImageContextEntry({
    required this.imagePath,
    required this.description,
    required this.timestamp,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late SpeechService _speech;
  late CameraService _camera;
  late BackendService _backend;
  late ExamModeService _exam;
  late AppState _app;

  bool _initialized = false;
  bool _guidanceRunning = false;
  String _status = '';
  String _lastSpokenLower = '';
  bool _hasMicPermission = false;
  bool _hasCameraPermission = false;
  final List<String> _speakLog = [];
  final TextEditingController _nameController = TextEditingController();
  String _selectedLanguageCode = 'en-IN';
  static const int _descriptionSuppressSeconds = 20;
  final Map<String, DateTime> _recentDescriptions = {};
  bool _showText = true;
  static const List<String> _modeOrder = [
    'visual',
    'road',
    'atm',
    'exam',
    'translate',
  ];
  int _selectedModeIndex = 0;

  String? _activeMode; // visual, road, atm, exam, translate
  final List<_ImageContextEntry> _recentImageContexts = [];
  bool _questionModeActive = false;
  String? _lastModeBeforeQuestion;
  bool _editingProfile = false;

  HttpServer? _pcHelperServer;
  String? _pcHelperServerAddress;
  int? _pcHelperServerPort;
  Completer<String?>? _pcHelperClientIpCompleter;

  static const MethodChannel _hardwareChannel = MethodChannel('hardware_buttons');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _speech = context.read<SpeechService>();
      _camera = context.read<CameraService>();
      _backend = context.read<BackendService>();
      _exam = context.read<ExamModeService>();
      _app = context.read<AppState>();
      _setupHardwareButtons();
      _init();
      _initialized = true;
    }
  }

  void _setupHardwareButtons() {
    _hardwareChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'volumeUpDouble':
          await _onVolumeUpDouble();
          break;
        case 'volumeUpTriple':
          await _onVolumeUpTriple();
          break;
        case 'volumeDownDouble':
          await _onVolumeDownDouble();
          break;
        default:
          break;
      }
    });
  }

  String _formatCurrentTime() {
    final now = DateTime.now();
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(now.hour)}:${twoDigits(now.minute)}.${twoDigits(now.second)}';
  }

  bool _shouldSpeakDescription(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    final lower = trimmed.toLowerCase();

    String positionKey = '';
    if (lower.contains('on your left')) {
      positionKey = 'left';
    } else if (lower.contains('on your right')) {
      positionKey = 'right';
    } else if (lower.contains('in front of you')) {
      positionKey = 'center';
    }

    String distanceKey = '';
    if (lower.contains('very close, within half a meter')) {
      distanceKey = 'very_close';
    } else if (lower.contains('close, around one meter away')) {
      distanceKey = 'close_1m';
    } else if (lower.contains('a few meters away')) {
      distanceKey = 'few_meters';
    } else if (lower.contains('far away')) {
      distanceKey = 'far';
    }

    String key;
    if (positionKey.isNotEmpty && distanceKey.isNotEmpty) {
      key = '$positionKey|$distanceKey';
    } else {
      key = lower;
    }

    final now = DateTime.now();
    final lastTime = _recentDescriptions[key];
    if (lastTime != null &&
        now.difference(lastTime).inSeconds < _descriptionSuppressSeconds) {
      return false;
    }

    _recentDescriptions[key] = now;
    if (_recentDescriptions.length > 100) {
      _recentDescriptions.removeWhere((_, t) =>
          now.difference(t).inSeconds > _descriptionSuppressSeconds * 2);
    }

    return true;
  }

  Future<void> _init() async {
    setState(() {
      _status = 'Requesting permissions';
    });
    final micStatus = await Permission.microphone.request();
    final camStatus = await Permission.camera.request();

    _hasMicPermission = micStatus.isGranted;
    _hasCameraPermission = camStatus.isGranted;

    if (!_hasMicPermission || !_hasCameraPermission) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Required permissions not granted. Please enable microphone and camera in system settings, then restart the app.';
      });
      return;
    }

    try {
      setState(() {
        _status =
            'Initializing speech. First launch may take up to a minute while the offline model is prepared.';
      });
      await _speech.init(languageCode: _app.languageCode);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Failed to initialize speech service.';
      });
      return;
    }

    try {
      setState(() {
        _status = 'Initializing camera';
      });
      await _camera.init();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Camera not available. Audio-only features may still work.';
      });
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _nameController.text = _app.username ?? '';
      _selectedLanguageCode = _app.languageCode;
      if (!_app.isRegistered) {
        _status =
            'Please complete setup: enter your name and choose a language, then pick a mode.';
      } else {
        _status =
            'Welcome back ${_app.username}. Choose a mode below.';
      }
    });
  }

  void _selectMode(String mode) {
    final index = _modeOrder.indexOf(mode);
    if (index == -1) {
      return;
    }
    setState(() {
      _selectedModeIndex = index;
    });
  }

  Future<void> _say(String text) async {
    if (text.isEmpty) {
      return;
    }
    if (!mounted) {
      return;
    }
    _lastSpokenLower = text.toLowerCase();
    setState(() {
      final time = _formatCurrentTime();
      _speakLog.add('visual : $text : $time');
      if (_speakLog.length > 20) {
        _speakLog.removeRange(0, _speakLog.length - 20);
      }
      _status = text;
    });
    await _speech.speak(text);
  }

  Future<void> _onVolumeUpDouble() async {
    if (!_hasMicPermission) {
      return;
    }
    if (_activeMode != null) {
      await _stopCurrentMode();
      return;
    }

    await _startSelectedMode();
  }

  Future<void> _onVolumeUpTriple() async {
    if (!_app.isRegistered) {
      return;
    }
    await _stopCurrentMode();
    setState(() {
      _selectedModeIndex = (_selectedModeIndex + 1) % _modeOrder.length;
    });
    await _startSelectedMode();
  }

  Future<void> _onVolumeDownDouble() async {
    if (!_hasMicPermission) {
      return;
    }
    final previousMode = _activeMode;
    await _stopCurrentMode();
    await _startQuestionMode(previousMode: previousMode);
  }

  Future<void> _announceSelectedMode() async {
    final mode = _modeOrder[_selectedModeIndex];
    String name;
    switch (mode) {
      case 'visual':
        name = 'Visual mode';
        break;
      case 'road':
        name = 'Road walk mode';
        break;
      case 'atm':
        name = 'ATM mode';
        break;
      case 'exam':
        name = 'Exam mode';
        break;
      case 'translate':
        name = 'Translate mode';
        break;
      default:
        name = 'Visual mode';
        break;
    }
    await _say('$name selected. Double press volume up to start.');
  }

  Future<void> _saveSetup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _status = 'Please enter your name to continue.';
      });
      await _say('Please enter your name to continue.');
      return;
    }
    final languageCode = _selectedLanguageCode;
    await _speech.setLanguage(languageCode);
    await _app.saveUser(name, languageCode);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Setup complete. Choose a mode below.';
    });
    await _say('Setup complete. You can now choose a mode.');
  }

  Future<void> _saveProfileChanges() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _status = 'Please enter your name to continue.';
      });
      await _say('Please enter your name to continue.');
      return;
    }
    final languageCode = _selectedLanguageCode;
    await _speech.setLanguage(languageCode);
    await _app.saveUser(name, languageCode);
    if (!mounted) {
      return;
    }
    setState(() {
      _editingProfile = false;
      _status = 'Profile updated.';
    });
    await _say('Your profile has been updated.');
  }

  Future<void> _startSelectedMode() async {
    final mode = _modeOrder[_selectedModeIndex];
    if (mode == 'visual') {
      await _startGuidance();
    } else if (mode == 'road') {
      await _startRoadMode();
    } else if (mode == 'atm') {
      await _startAtmMode();
    } else if (mode == 'exam') {
      await _toggleExamMode();
    } else if (mode == 'translate') {
      await _startTranslateInteraction();
    }
  }

  Future<void> _stopCurrentMode() async {
    final mode = _activeMode;
    if (mode == null) {
      return;
    }

    await _speech.stopSpeaking();

    if (mode == 'visual' || mode == 'road' || mode == 'atm') {
      // Let the running guidance loop see this flag and cleanly stop,
      // including stopping camera capture and announcing that guidance
      // has stopped.
      _guidanceRunning = false;
    } else if (mode == 'exam') {
      if (_app.examModeEnabled) {
        await _exam.disconnect();
        _app.setExamMode(false);
        await _say('Exam mode stopped.');
      }
    } else if (mode == 'translate') {
      await _speech.stopSpeaking();
    }

    _activeMode = null;
  }

  void _storeImageContext(String imagePath, String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _recentImageContexts.add(
      _ImageContextEntry(
        imagePath: imagePath,
        description: trimmed,
        timestamp: DateTime.now(),
      ),
    );
    if (_recentImageContexts.length > 4) {
      final toRemoveCount = _recentImageContexts.length - 4;
      final removed = _recentImageContexts.sublist(0, toRemoveCount);
      for (final entry in removed) {
        try {
          final file = File(entry.imagePath);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      _recentImageContexts.removeRange(0, toRemoveCount);
    }
  }

  Future<Position?> _tryGetLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return null;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _startQuestionMode({String? previousMode}) async {
    if (_questionModeActive) {
      return;
    }
    _questionModeActive = true;
    _lastModeBeforeQuestion = previousMode;

    await _speech.stopSpeaking();
    await _say(
      'Question mode. You can ask about the last images or any general question. Please speak now.',
    );

    final question = await _listenOnce(timeout: const Duration(seconds: 10));
    if (question.isEmpty) {
      await _say('I did not hear a clear question.');
      _questionModeActive = false;
      final mode = _lastModeBeforeQuestion;
      _lastModeBeforeQuestion = null;
      if (mode != null) {
        _selectMode(mode);
        await _startSelectedMode();
      }
      return;
    }

    final imagePaths = _recentImageContexts
        .map((e) => e.imagePath)
        .toList(growable: false);

    Position? position;
    final locationStatus = await Permission.locationWhenInUse.request();
    if (locationStatus.isGranted) {
      position = await _tryGetLocation();
    }

    final answer = await _backend.answerQuestionWithGemini(
      question: question,
      languageCode: _app.languageCode,
      imagePaths: imagePaths,
      latitude: position?.latitude,
      longitude: position?.longitude,
    );

    if (answer.isEmpty) {
      await _say(
        'I could not find a clear answer. Please try capturing a new image and ask again.',
      );
    } else {
      await _say(answer);
    }

    _questionModeActive = false;
    final mode = _lastModeBeforeQuestion;
    _lastModeBeforeQuestion = null;
    if (mode != null) {
      _selectMode(mode);
      await _startSelectedMode();
    }
  }

  String _sanitizeRecognizedText(String text) {
    var result = text.trim();
    if (result.isEmpty) {
      return '';
    }
    final lower = result.toLowerCase();

    // 1) Onboarding name confirmation (legacy) and any similar prompt text
    // that includes "is your name pronounced correctly".
    if (lower.contains('is your name pronounced correctly')) {
      const marker = 'say yes or no';
      final idx = lower.indexOf(marker);
      if (idx != -1) {
        final after = result.substring(idx + marker.length).trim();
        if (after.isNotEmpty) {
          // Keep only the user's "yes" / "no" part.
          return after;
        }
        // Pure echo of the prompt with no answer.
        return '';
      }
    }

    // 2) Language selection style prompts that end with the word "english".
    if (lower.contains('what language do you prefer') ||
        lower.contains('say english to continue')) {
      final parts = lower.split(RegExp('\\s+'));
      if (parts.isNotEmpty && parts.last == 'english') {
        // Normalize to just "english" so it logs as user : English.
        return 'english';
      }
      // Echoed the question but no clear answer word.
      return '';
    }

    // 3) Pure system prompts that should never be treated as user input.
    if (lower.contains('setup complete') &&
        lower.contains('exam mode') &&
        lower.contains('visual mode')) {
      return '';
    }

    if (lower.contains('say exam mode') &&
        lower.contains('visual mode') &&
        lower.contains('exit the app')) {
      return '';
    }

    if (lower.contains('exam mode connects to your exam computer')) {
      return '';
    }

    if (lower.contains(
        'exam mode cancelled because no computer address was entered')) {
      return '';
    }

    if (lower.contains('listening to surrounding speech') &&
        lower.contains('please speak now')) {
      return '';
    }

    if (lower.contains('i could not understand the speech')) {
      return '';
    }

    // Filter out echoes of the app's own visual descriptions such as
    // "I see a chair on your left, very close, within half a meter".
    if (lower.startsWith('i see ') &&
        (lower.contains('on your left') ||
            lower.contains('on your right') ||
            lower.contains('in front of you'))) {
      return '';
    }

    // More general echo filter: if the recognized fragment shares several
    // words with the last full sentence spoken by the app (for example,
    // just "left very close within half a meter" or "a few meters away"),
    // treat it as an echo, not as a real user utterance.
    if (_lastSpokenLower.isNotEmpty) {
      final frag = lower.trim();
      if (frag.length >= 8) {
        String normalize(String s) => s
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');

        final fragWords = normalize(frag)
            .split(RegExp(r'\s+'))
            .where((w) => w.length >= 3)
            .toList();
        final lastWords = normalize(_lastSpokenLower)
            .split(RegExp(r'\s+'))
            .where((w) => w.length >= 3)
            .toSet();

        int overlap = 0;
        for (final w in fragWords) {
          if (lastWords.contains(w)) {
            overlap++;
          }
        }

        if (overlap >= 3) {
          return '';
        }
      }
    }

    return result;
  }

  Future<String> _listenOnce({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final completer = Completer<String>();
    await _speech.startListening(
      (text) {
        if (!completer.isCompleted) {
          completer.complete(text);
        }
      },
      localeId: _app.languageCode,
      listenFor: timeout,
    );
    try {
      final raw = await completer.future.timeout(timeout);
      String result = raw;
      // Vosk may return JSON like {"text": "hello"}; try to parse it.
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['text'] is String) {
          result = decoded['text'] as String;
        }
      } catch (_) {}
      // Clean up any echoes of the app's own prompts and try to keep only
      // the short user answer (for example just "no" or "english").
      result = _sanitizeRecognizedText(result);
      if (result.isEmpty) {
        return '';
      }
      if (mounted) {
        setState(() {
          final time = _formatCurrentTime();
          _speakLog.add('user : $result : $time');
          if (_speakLog.length > 20) {
            _speakLog.removeRange(0, _speakLog.length - 20);
          }
        });
      }
      return result;
    } on TimeoutException {
      await _speech.stopListening();
      return '';
    }
  }

  Future<void> _startGuidance({String? intro}) async {
    if (_app.examModeEnabled) {
      await _say(
        'Exam or PC mode is active. Please exit exam mode before using camera guidance modes.',
      );
      return;
    }
    if (_guidanceRunning) {
      return;
    }
    _activeMode ??= 'visual';
    _guidanceRunning = true;
    _app.setGuidanceActive(true);
    await _say(
      intro ?? 'Starting visual guidance. Say stop guidance to stop.',
    );

    _camera.startPeriodicCapture(const Duration(seconds: 5), (file) async {
      final description = await _backend.analyzeImage(
        file.path,
        _app.languageCode,
        useGemini: AppConfig.geminiApiKey.isNotEmpty,
      );

      // If the Gemini vision call failed, surface the error in the on-screen
      // log so the user can see why Gemini was not used (for example in a
      // release build where debug prints are not visible).
      final geminiError = _backend.takeLastGeminiError();
      if (geminiError != null && geminiError.isNotEmpty && mounted) {
        setState(() {
          final time = _formatCurrentTime();
          _speakLog.add('visual (debug) : Gemini error: $geminiError : $time');
          if (_speakLog.length > 20) {
            _speakLog.removeRange(0, _speakLog.length - 20);
          }
        });
      }

      if (description.isNotEmpty) {
        _storeImageContext(file.path, description);
        if (_shouldSpeakDescription(description)) {
          await _say(description);
        }
      }
    });

    while (_guidanceRunning && mounted) {
      final command = (await _listenOnce(timeout: const Duration(seconds: 6))).toLowerCase();
      if (command.isEmpty) {
        continue;
      }
      if (command.contains('stop guidance') ||
          command.contains('stop') ||
          command.contains('exit') ||
          command.contains('back') ||
          command.contains('menu')) {
        _guidanceRunning = false;
      } else if (command.contains('exam')) {
        _guidanceRunning = false;
        await _camera.stopPeriodicCapture();
        _app.setGuidanceActive(false);
        await _say('Stopping guidance and switching to exam mode.');
        await _startExamMode();
        return;
      } else if (command.contains('transcribe')) {
        await _handleTranscribe();
      } else if (command.contains('what is it used for') ||
          command.contains('what is this used for') ||
          command.contains('purpose of this') ||
          command.contains('what is the purpose')) {
        final usage =
            await _backend.describeLastObjectUsage(_app.languageCode);
        if (usage.isEmpty) {
          await _say('I do not have usage information for the last object.');
        } else {
          await _say(usage);
        }
      } else if (command.contains('what is the size') ||
          command.contains('how big is it') ||
          command.contains('how small is it') ||
          command.contains('tell me the size')) {
        final sizeDescription =
            await _backend.describeLastObjectSize(_app.languageCode);
        if (sizeDescription.isEmpty) {
          await _say('I do not have size information for the last object.');
        } else {
          await _say(sizeDescription);
        }
      }
    }

    await _camera.stopPeriodicCapture();
    _app.setGuidanceActive(false);
    await _say('Guidance stopped.');
    if (_activeMode == 'visual' || _activeMode == 'road' || _activeMode == 'atm') {
      _activeMode = null;
    }
  }

  Future<void> _startRoadMode() async {
    _activeMode = 'road';
    await _startGuidance(
      intro:
          'Starting road walk mode. I will guide you while walking on the road and crossing the road. Say stop guidance to stop.',
    );
  }

  Future<void> _startAtmMode() async {
    _activeMode = 'atm';
    await _startGuidance(
      intro:
          'Starting ATM mode. I will help you understand the ATM and identify money notes and coins. Say stop guidance to stop.',
    );
  }

  Future<void> _handleTranscribe() async {
    await _say('Listening to surrounding speech. Please speak now.');
    final text = await _listenOnce(timeout: const Duration(seconds: 8));
    if (text.isEmpty) {
      await _say('I could not understand the speech.');
    } else {
      await _say('I heard the following speech.');
      await _speech.speak(text);
    }
  }

  Future<void> _startTranslateInteraction() async {
    if (_app.examModeEnabled) {
      await _say(
        'Exam or PC mode is active. Please exit exam mode before using translate mode.',
      );
      return;
    }
    _activeMode = 'translate';
    await _say('Translate mode. Please speak a short sentence to translate.');
    final text = await _listenOnce(timeout: const Duration(seconds: 8));
    if (text.isEmpty) {
      await _say('I could not understand the speech.');
      return;
    }
    final translated =
        await _backend.translateWithGemini(text, _app.languageCode);
    if (translated.isEmpty) {
      await _say('I could not translate the speech.');
    } else {
      await _say(translated);
    }
    if (_activeMode == 'translate') {
      _activeMode = null;
    }
  }

  Future<String?> _findLocalIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('10.') ||
              ip.startsWith('192.168.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _stopPcHelperFileServer() async {
    final server = _pcHelperServer;
    _pcHelperServer = null;
    _pcHelperServerAddress = null;
    _pcHelperServerPort = null;
    final completer = _pcHelperClientIpCompleter;
    _pcHelperClientIpCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _startPcHelperFileServer() async {
    if (_pcHelperServer != null) {
      return;
    }
    final ip = await _findLocalIPv4();
    if (ip == null) {
      await _say(
        'I could not find my Wi-Fi address. Please make sure your phone is connected to Wi-Fi and try again.',
      );
      return;
    }
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _pcHelperServer = server;
      _pcHelperServerAddress = ip;
      _pcHelperServerPort = server.port;
      _pcHelperClientIpCompleter = Completer<String?>();
      _servePcHelper(server);
    } catch (_) {
      await _say('I could not start the PC helper download server.');
      await _stopPcHelperFileServer();
    }
  }

  Future<void> _servePcHelper(HttpServer server) async {
    const assetPath = 'assets/pc_helper/VisualEyesPC.exe';
    await for (final request in server) {
      if (request.method == 'GET' &&
          (request.uri.path == '/' ||
              request.uri.path == '/VisualEyesPC.exe' ||
              request.uri.path == '/pc-helper')) {
        try {
          final data = await rootBundle.load(assetPath);
          final bytes = data.buffer.asUint8List();
          final clientIp = request.connectionInfo?.remoteAddress.address;
          if (clientIp != null) {
            final completer = _pcHelperClientIpCompleter;
            if (completer != null && !completer.isCompleted) {
              completer.complete(clientIp);
            }
          }
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set(
            'Content-Disposition',
            'attachment; filename="VisualEyesPC.exe"',
          );
          request.response.add(bytes);
          await request.response.close();
        } catch (_) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    }
  }

  Future<String?> _runPcHelperSetup() async {
    await _startPcHelperFileServer();
    final ip = _pcHelperServerAddress;
    final port = _pcHelperServerPort;
    if (ip == null || port == null) {
      await _stopPcHelperFileServer();
      return null;
    }

    final url = 'http://$ip:$port/VisualEyesPC.exe';
    if (mounted) {
      setState(() {
        _status =
            'PC helper setup. Open this address in a browser on your computer: $url';
        final time = _formatCurrentTime();
        _speakLog.add('visual : PC helper download link: $url : $time');
        if (_speakLog.length > 20) {
          _speakLog.removeRange(0, _speakLog.length - 20);
        }
      });
    }

    await _say(
      'PC mode first-time setup. On your computer, open a browser on the same Wi-Fi and type the address shown on the screen to download the VisualEyes PC helper.',
    );

    final completer = _pcHelperClientIpCompleter;
    if (completer == null) {
      await _stopPcHelperFileServer();
      return null;
    }

    String? clientIp;
    try {
      clientIp = await completer.future
          .timeout(const Duration(minutes: 10));
    } on TimeoutException {
      await _say(
        'I did not see any computer download the helper within ten minutes. Cancelling PC mode setup.',
      );
      await _stopPcHelperFileServer();
      return null;
    }

    await _stopPcHelperFileServer();

    if (!mounted) {
      return null;
    }

    if (clientIp == null || clientIp.isEmpty) {
      await _say(
        'I could not detect the computer address. Please try again later.',
      );
      return null;
    }

    final wsUrl = 'ws://$clientIp:8765';
    await _app.saveExamServerUrl(wsUrl);
    await _say(
      'I detected a computer at address $clientIp. Please install and run the VisualEyes PC helper on that computer. When it is ready, double press volume up again to connect.',
    );
    return wsUrl;
  }

  Future<void> _startExamMode() async {
    // Ensure any running camera-based guidance is fully stopped before
    // entering exam/PC mode.
    _guidanceRunning = false;
    await _camera.stopPeriodicCapture();
    _app.setGuidanceActive(false);

    String? url = _app.examServerUrl;
    if (url == null) {
      final autoUrl = await _runPcHelperSetup();
      if (!mounted) {
        return;
      }
      if (autoUrl == null) {
        await _say(
          'Automatic PC companion setup did not complete. I will ask you to enter the computer address manually.',
        );
        final entered = await _promptExamServerUrl();
        if (!mounted) {
          return;
        }
        if (entered == null || entered.isEmpty) {
          await _say(
            'Exam mode cancelled because no computer address was entered.',
          );
          return;
        }

        var trimmed = entered.trim();
        if (!trimmed.startsWith('ws://') &&
            !trimmed.startsWith('wss://')) {
          if (!trimmed.contains(':')) {
            trimmed = 'ws://$trimmed:8765';
          } else {
            trimmed = 'ws://$trimmed';
          }
        }
        url = trimmed;
        await _app.saveExamServerUrl(url);
      } else {
        return;
      }
    }

    _app.setExamMode(true);
    _activeMode = 'exam';
    try {
      _exam.connect(url!);
      await _say(
        'Exam mode is ready. Your phone is now connected to the exam computer.',
      );
    } catch (_) {
      await _say(
        'I could not connect to the exam computer. Please check the IP address and that the desktop companion is running.',
      );
    }
  }

  Future<void> _toggleExamMode() async {
    if (_app.examModeEnabled) {
      await _exam.disconnect();
      _app.setExamMode(false);
      await _say('Exam mode stopped.');
      if (_activeMode == 'exam') {
        _activeMode = null;
      }
    } else {
      await _startExamMode();
    }
  }

  Future<String?> _promptExamServerUrl() async {
    final controller = TextEditingController(
      text: _app.examServerUrl ?? AppConfig.examWebsocketUrl,
    );
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Exam computer IP address'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'e.g. 192.168.0.10:8765 or ws://192.168.0.10:8765',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _exitApp() async {
    await _speech.stopSpeaking();
    SystemNavigator.pop();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: Text(
                  'VisualEyes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!_app.isRegistered) ...[
                TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    labelStyle: TextStyle(color: Colors.white),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.blue),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Language:',
                      style: TextStyle(color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: _selectedLanguageCode,
                      dropdownColor: Colors.black,
                      style: const TextStyle(color: Colors.white),
                      items: const [
                        DropdownMenuItem(
                          value: 'en-IN',
                          child: Text('English'),
                        ),
                        DropdownMenuItem(
                          value: 'ta-IN',
                          child: Text('Tamil'),
                        ),
                        DropdownMenuItem(
                          value: 'ml-IN',
                          child: Text('Malayalam'),
                        ),
                        DropdownMenuItem(
                          value: 'hi-IN',
                          child: Text('Hindi'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _selectedLanguageCode = value;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _saveSetup,
                  child: const Text('Save and continue'),
                ),
                const SizedBox(height: 16),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_app.username != null)
                      Text(
                        'Welcome ${_app.username}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _editingProfile = !_editingProfile;
                          _nameController.text = _app.username ?? '';
                          _selectedLanguageCode = _app.languageCode;
                        });
                      },
                      child: Text(
                        _editingProfile ? 'Cancel edit' : 'Edit profile',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                if (_editingProfile) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      labelStyle: TextStyle(color: Colors.white),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.blue),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'Language:',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: _selectedLanguageCode,
                        dropdownColor: Colors.black,
                        style: const TextStyle(color: Colors.white),
                        items: const [
                          DropdownMenuItem(
                            value: 'en-IN',
                            child: Text('English'),
                          ),
                          DropdownMenuItem(
                            value: 'ta-IN',
                            child: Text('Tamil'),
                          ),
                          DropdownMenuItem(
                            value: 'ml-IN',
                            child: Text('Malayalam'),
                          ),
                          DropdownMenuItem(
                            value: 'hi-IN',
                            child: Text('Hindi'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _selectedLanguageCode = value;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _saveProfileChanges,
                    child: const Text('Save profile'),
                  ),
                  const SizedBox(height: 16),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final buttonWidth = (constraints.maxWidth - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () async {
                              _selectMode('visual');
                              await _startGuidance();
                            },
                            child: const Text('Visual mode'),
                          ),
                        ),
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () async {
                              _selectMode('road');
                              await _startRoadMode();
                            },
                            child: const Text('Road walk mode'),
                          ),
                        ),
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () async {
                              _selectMode('atm');
                              await _startAtmMode();
                            },
                            child: const Text('ATM mode'),
                          ),
                        ),
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () async {
                              _selectMode('exam');
                              await _toggleExamMode();
                            },
                            child: const Text('Exam mode'),
                          ),
                        ),
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _showText = !_showText;
                              });
                            },
                            child: Text(_showText ? 'Hide text' : 'Show text'),
                          ),
                        ),
                        SizedBox(
                          width: buttonWidth,
                          child: ElevatedButton(
                            onPressed: () async {
                              _selectMode('translate');
                              await _startTranslateInteraction();
                            },
                            child: const Text('Translate'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
              Expanded(
                child: !_showText
                    ? Center(
                        child: Text(
                          _status.isEmpty
                              ? 'VisualEyes is running'
                              : _status,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : (_speakLog.isEmpty
                        ? Center(
                            child: Text(
                              _status.isEmpty
                                  ? 'No messages yet.'
                                  : _status,
                              style: const TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: _speakLog.length,
                            itemBuilder: (context, index) {
                              final raw =
                                  _speakLog[_speakLog.length - 1 - index];
                              final entry = _parseLogEntry(raw);
                              return Align(
                                alignment: entry.isUser
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                      vertical: 4),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                    horizontal: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: entry.isUser
                                        ? Colors.blueGrey.shade700
                                        : Colors.grey.shade800,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Align(
                                        alignment:
                                            Alignment.centerLeft,
                                        child: Text(
                                          entry.text,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Align(
                                        alignment:
                                            Alignment.bottomRight,
                                        child: Text(
                                          entry.time,
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _LogEntry _parseLogEntry(String raw) {
    final parts = raw.split(' : ');
    if (parts.length >= 3) {
      final speaker = parts.first.trim().toLowerCase();
      final time = parts.last.trim();
      final message = parts.sublist(1, parts.length - 1).join(' : ').trim();
      final isUser = speaker.startsWith('user');
      return _LogEntry(
        isUser: isUser,
        text: message,
        time: time,
      );
    }
    return _LogEntry(
      isUser: false,
      text: raw,
      time: '',
    );
  }
}
