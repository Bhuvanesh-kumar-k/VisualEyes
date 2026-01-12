class AppConfig {
  static const String examWebsocketUrl = 'ws://192.168.0.100:8765';
  static const String geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );
  static const String geminiVisionModel = 'gemini-2.0-flash';
}
