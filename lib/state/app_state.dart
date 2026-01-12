import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppState extends ChangeNotifier {
  String? _username;
  String _languageCode = 'en-IN';
  bool _registered = false;
  bool _guidanceActive = false;
  bool _examMode = false;
  String? _examServerUrl;
  bool _useGeminiVision = false;
  String _visionEngine = 'local_ai'; // mlkit, local_ai, gemini
  String? _visionServerUrl;

  AppState() {
    load();
  }

  String? get username => _username;
  String get languageCode => _languageCode;
  bool get isRegistered => _registered;
  bool get guidanceActive => _guidanceActive;
  bool get examModeEnabled => _examMode;
  String? get examServerUrl => _examServerUrl;
  bool get useGeminiVision => _useGeminiVision;
  String get visionEngine => _visionEngine;
  String? get visionServerUrl => _visionServerUrl;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _username = prefs.getString('username');
    _languageCode = prefs.getString('languageCode') ?? 'en-IN';
    _registered = _username != null;
    _examServerUrl = prefs.getString('examServerUrl');
    _useGeminiVision = prefs.getBool('useGeminiVision') ?? false;
    _visionEngine = prefs.getString('visionEngine') ?? 'local_ai';
    _visionServerUrl = prefs.getString('visionServerUrl');
    notifyListeners();
  }

  Future<void> saveUser(String username, String languageCode) async {
    _username = username;
    _languageCode = languageCode;
    _registered = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', username);
    await prefs.setString('languageCode', languageCode);
    notifyListeners();
  }

  Future<void> saveExamServerUrl(String url) async {
    _examServerUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('examServerUrl', url);
    notifyListeners();
  }

  Future<void> setUseGeminiVision(bool value) async {
    _useGeminiVision = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('useGeminiVision', value);
    notifyListeners();
  }

  Future<void> saveVisionEngine(String engine) async {
    _visionEngine = engine;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('visionEngine', engine);
    notifyListeners();
  }

  Future<void> saveVisionServerUrl(String url) async {
    _visionServerUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('visionServerUrl', url);
    notifyListeners();
  }

  void setGuidanceActive(bool active) {
    _guidanceActive = active;
    notifyListeners();
  }

  void setExamMode(bool enabled) {
    _examMode = enabled;
    notifyListeners();
  }
}
