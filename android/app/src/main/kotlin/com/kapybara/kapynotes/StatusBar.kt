package com.kapybara.kapynotes

import android.app.Activity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Backs the `kapynotes/status_bar` channel: the status bar, hidden while a
 * phone on its side has the keyboard up and shown again after.
 *
 * Only the bar's visibility changes. The window keeps the system UI mode it
 * was given, edge-to-edge on Android 15 and later, so showing the bar puts the
 * app back as it was. While it is hidden, a swipe from the top shows it over
 * the app for a moment, as in any app that hides it.
 */
object StatusBar {
    private const val CHANNEL = "kapynotes/status_bar"

    fun register(messenger: BinaryMessenger, activity: Activity): MethodChannel {
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            val window = activity.window
            val bars = WindowCompat.getInsetsController(window, window.decorView)
            when (call.method) {
                "hide" -> {
                    bars.systemBarsBehavior =
                        WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    bars.hide(WindowInsetsCompat.Type.statusBars())
                    result.success(null)
                }
                "show" -> {
                    bars.show(WindowInsetsCompat.Type.statusBars())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }
}
