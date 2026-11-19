package com.kapybara.kapynotes

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Backs the `kapynotes/contrast` channel: whether High contrast text is on in
 * Settings › Accessibility.
 *
 * Flutter reads Android 14's contrast level, but not this older and better
 * known switch, so Dart asks here once and is told each time it changes.
 * Android 16 has a public API for it; before that it is the secure setting
 * the switch writes, read defensively because the platform may refuse.
 */
class ContrastSetting private constructor(
    private val context: Context,
    private val channel: MethodChannel,
) {
    private val resolver: ContentResolver = context.contentResolver
    private var stopListening: () -> Unit = {}

    private fun start() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "increaseContrast" -> result.success(current())
                else -> result.notImplemented()
            }
        }
        val changed = { channel.invokeMethod("changed", current()) }
        if (Build.VERSION.SDK_INT >= 36) {
            val manager = context.getSystemService(AccessibilityManager::class.java) ?: return
            val listener = AccessibilityManager.HighContrastTextStateChangeListener { changed() }
            manager.addHighContrastTextStateChangeListener(context.mainExecutor, listener)
            stopListening = { manager.removeHighContrastTextStateChangeListener(listener) }
        } else {
            val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) = changed()
            }
            resolver.registerContentObserver(Settings.Secure.getUriFor(SETTING), false, observer)
            stopListening = { resolver.unregisterContentObserver(observer) }
        }
    }

    private fun current(): Boolean {
        if (Build.VERSION.SDK_INT >= 36) {
            return context.getSystemService(AccessibilityManager::class.java)
                ?.isHighContrastTextEnabled == true
        }
        return try {
            Settings.Secure.getInt(resolver, SETTING, 0) == 1
        } catch (refused: SecurityException) {
            false
        }
    }

    fun close() {
        stopListening()
        stopListening = {}
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL = "kapynotes/contrast"
        private const val SETTING = "high_text_contrast_enabled"

        fun register(context: Context, messenger: BinaryMessenger): ContrastSetting =
            ContrastSetting(context.applicationContext, MethodChannel(messenger, CHANNEL))
                .also { it.start() }
    }
}
