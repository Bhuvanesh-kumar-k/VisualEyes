package com.example.visual

import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var hardwareChannel: MethodChannel? = null

    private val handler = Handler(Looper.getMainLooper())

    private var lastVolumeUpTime: Long = 0
    private var volumeUpCount: Int = 0
    private var volumeUpRunnable: Runnable? = null

    private var lastVolumeDownTime: Long = 0
    private var volumeDownCount: Int = 0
    private var volumeDownRunnable: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        hardwareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hardware_buttons"
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                handleVolumeUp()
                // Consume the event so the system does not change the volume.
                return true
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                handleVolumeDown()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun handleVolumeUp() {
        val now = System.currentTimeMillis()
        if (now - lastVolumeUpTime > 600) {
            volumeUpCount = 0
        }
        lastVolumeUpTime = now
        volumeUpCount += 1

        volumeUpRunnable?.let { handler.removeCallbacks(it) }

        if (volumeUpCount == 2) {
            volumeUpRunnable = Runnable {
                if (volumeUpCount == 2) {
                    hardwareChannel?.invokeMethod("volumeUpDouble", null)
                }
                volumeUpCount = 0
            }
            handler.postDelayed(volumeUpRunnable!!, 350)
        } else if (volumeUpCount == 3) {
            // Triple press detected, cancel pending double.
            volumeUpRunnable?.let { handler.removeCallbacks(it) }
            hardwareChannel?.invokeMethod("volumeUpTriple", null)
            volumeUpCount = 0
        }
    }

    private fun handleVolumeDown() {
        val now = System.currentTimeMillis()
        if (now - lastVolumeDownTime > 600) {
            volumeDownCount = 0
        }
        lastVolumeDownTime = now
        volumeDownCount += 1

        volumeDownRunnable?.let { handler.removeCallbacks(it) }

        if (volumeDownCount == 2) {
            volumeDownRunnable = Runnable {
                if (volumeDownCount == 2) {
                    hardwareChannel?.invokeMethod("volumeDownDouble", null)
                }
                volumeDownCount = 0
            }
            handler.postDelayed(volumeDownRunnable!!, 350)
        }
    }
}
