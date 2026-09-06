package com.kapybara.kapynotes

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity behind the Flutter app, and the one question Dart asks the
 * platform on the way up: why am I open?
 *
 * The Write widget is the only thing that answers anything but "normally",
 * and it does so by naming its own action on the intent that starts this
 * activity. The answer is handed over once and then cleared, so that a later
 * launch from the icon cannot inherit a tap on the widget.
 */
class MainActivity : FlutterActivity() {
    private var pendingLaunch: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLaunch = launchNameOf(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchIntent" -> {
                        result.success(pendingLaunch)
                        pendingLaunch = null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * A tap on the widget while the app is already running.
     *
     * Nothing more is needed here: the app is on the note the widget would
     * have opened, and resuming is what puts the caret back at the end of it.
     * Recording the action anyway keeps the answer right for a Dart side that
     * has not asked yet, which is the case when the process was alive but the
     * engine had not finished starting.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pendingLaunch = launchNameOf(intent) ?: pendingLaunch
    }

    private fun launchNameOf(intent: Intent?): String? =
        if (intent?.action == ACTION_CONTINUE_WRITING) CONTINUE_WRITING else null

    companion object {
        /** What the Write widget names on the intent it starts this with. */
        const val ACTION_CONTINUE_WRITING = "com.kapybara.kapynotes.CONTINUE_WRITING"

        private const val CHANNEL = "kapynotes/quick_capture"

        /** Matches `LaunchIntent.continueWriting` on the Dart side. */
        private const val CONTINUE_WRITING = "continueWriting"
    }
}
