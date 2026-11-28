package com.kapybara.kapynotes

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `kapynotes/recording_controls` channel: lib/audio/recording_controls.dart.
 *
 * Dart shows and hides a recording's notification through it, and a press on
 * one of the notification's buttons goes back the same way. It lasts as long
 * as the engine does, and the activity closes it with the engine, taking the
 * notification away: nothing would be left behind it to record.
 */
class RecordingControls private constructor(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    private var asking: MethodChannel.Result? = null

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "show" -> {
                RecordingService.show(
                    activity.applicationContext,
                    elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L,
                    paused = call.argument<Boolean>("paused") ?: false,
                    interrupted = call.argument<Boolean>("interrupted") ?: false,
                    phrase = call.argument<String>("phrase"),
                    heard = call.argument<String>("heard"),
                    live = call.argument<Boolean>("live") ?: false,
                )
                result.success(null)
            }
            "hide" -> {
                RecordingService.hide(activity.applicationContext)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Asks to post notifications the first time anybody records, on Android
     * 13 and later, and never again: somebody who said no meant it. Answers
     * once the question is, whatever the answer, because the recording goes
     * ahead either way and only its notification goes unseen.
     */
    private fun prepare(result: MethodChannel.Result) {
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED ||
            prefs.getBoolean(ASKED, false) ||
            asking != null
        ) {
            result.success(null)
            return
        }
        prefs.edit().putBoolean(ASKED, true).apply()
        asking = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE,
        )
    }

    /** The activity passing on the answer to [prepare]'s question. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        asking?.success(null)
        asking = null
    }

    fun close() {
        channel.setMethodCallHandler(null)
        asking = null
        if (current === this) current = null
        RecordingService.hide(activity.applicationContext)
    }

    companion object {
        private const val CHANNEL = "kapynotes/recording_controls"
        private const val PREFS = "recording_controls"
        private const val ASKED = "askedToNotify"
        private const val REQUEST_CODE = 0x5243

        /** The engine a press goes to. Main thread only. */
        private var current: RecordingControls? = null

        fun register(activity: Activity, messenger: BinaryMessenger): RecordingControls {
            val channel = MethodChannel(messenger, CHANNEL)
            val controls = RecordingControls(activity, channel)
            channel.setMethodCallHandler(controls::handle)
            current = controls
            return controls
        }

        /**
         * A press on the notification, for Dart. False when there is no app
         * to take it. Dart answering that there is no recording takes the
         * notification away too.
         */
        fun press(context: Context, command: String): Boolean {
            val channel = current?.channel ?: return false
            channel.invokeMethod(
                command,
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) RecordingService.hide(context.applicationContext)
                    }

                    override fun error(code: String, message: String?, details: Any?) {}

                    override fun notImplemented() = RecordingService.hide(context.applicationContext)
                },
            )
            return true
        }
    }
}
