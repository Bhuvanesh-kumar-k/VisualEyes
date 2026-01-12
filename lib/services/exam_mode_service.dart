import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class ExamModeService {
  WebSocketChannel? _channel;

  void connect(String wsUrl) {
    _channel?.sink.close();
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
  }

  Stream<dynamic>? get messages => _channel?.stream;

  void sendCommand(Map<String, dynamic> command) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(jsonEncode(command));
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
  }
}
