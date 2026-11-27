package com.kapybara.kapynotes

import android.app.Activity
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.StatFs
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Backs the `kapynotes/camera` channel: what the note camera asks of the phone
 * around it (lib/images/camera_capture.dart).
 *
 * Free space is measured where the camera writes its recording, the cache.
 * A call is read from the audio mode, which every app may read without a
 * permission: ringing, a phone call, or a call in another app all set it.
 */
object CameraSupport {
    private const val CHANNEL = "kapynotes/camera"

    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "freeBytes" -> result.success(StatFs(activity.cacheDir.path).availableBytes)
                "inCall" -> {
                    val mode = activity.getSystemService(AudioManager::class.java)?.mode
                    result.success(
                        mode == AudioManager.MODE_RINGTONE ||
                            mode == AudioManager.MODE_IN_CALL ||
                            mode == AudioManager.MODE_IN_COMMUNICATION,
                    )
                }
                "openSettings" -> {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", activity.packageName, null),
                        ),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
