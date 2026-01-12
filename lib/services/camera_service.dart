import 'dart:async';

import 'package:camera/camera.dart';

typedef FrameHandler = Future<void> Function(XFile file);

class CameraService {
  CameraController? _controller;
  Timer? _timer;
  bool _isCapturing = false;

  Future<void> init() async {
    final cameras = await availableCameras();
    CameraDescription? back;
    for (final c in cameras) {
      if (c.lensDirection == CameraLensDirection.back) {
        back = c;
        break;
      }
    }
    back ??= cameras.isNotEmpty ? cameras.first : null;
    if (back == null) {
      throw StateError('No camera found');
    }
    _controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _controller!.initialize();
  }

  CameraController? get controller => _controller;

  void startPeriodicCapture(Duration interval, FrameHandler onFrame) {
    _timer?.cancel();
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }
    _timer = Timer.periodic(interval, (timer) async {
      if (_isCapturing || _controller == null || !_controller!.value.isInitialized) {
        return;
      }
      _isCapturing = true;
      try {
        final picture = await _controller!.takePicture();
        await onFrame(picture);
      } finally {
        _isCapturing = false;
      }
    });
  }

  Future<void> stopPeriodicCapture() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    await stopPeriodicCapture();
    await _controller?.dispose();
    _controller = null;
  }
}
