package com.aura.aura

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var ring: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aura/ring").setMethodCallHandler { call, result ->
            if (call.method == "start") startRing() else stopRing()
            result.success(null)
        }
    }

    // Мелодия звонка из настроек телефона. Звук рингтона Android сам ведёт и в динамик, даже с наушниками;
    // с API 28 ещё и просим динамик явно. В беззвучном режиме громкость звонка 0, и телефон молчит, как положено.
    private fun startRing() {
        stopRing()
        ring = try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                        ?.let { setPreferredDevice(it) }
                }
                setDataSource(this@MainActivity, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.w("AURA", "мелодия звонка: $e") // например, в телефоне выбрано «Без звука»
            null
        }
    }

    private fun stopRing() {
        ring?.release()
        ring = null
    }

    override fun onDestroy() {
        stopRing()
        super.onDestroy()
    }
}
