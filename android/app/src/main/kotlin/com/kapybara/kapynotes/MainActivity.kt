package com.kapybara.kapynotes

import android.content.Context
import android.content.Intent
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity behind the Flutter app, and the one question Dart asks the
 * platform on the way up: why am I open?
 *
 * The widgets are the only things that answer anything but "normally", and
 * they do so by naming their own action on the intent that starts this
 * activity — see [QuickAction]. The answer is handed over once and then
 * cleared, so that a later launch from the icon cannot inherit a tap on a
 * widget, and so that a Capture the app has already acted on does not open
 * the picker again the next time Dart asks.
 */
class MainActivity : FlutterActivity() {
    private var pendingLaunch: String? = null

    /**
     * Lets code Play delivered after install — the speech runtime module —
     * be found by this activity's process without a restart. A no-op when
     * there is no such module, which is every debug build.
     */
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        SplitCompat.installActivity(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RichClipboard.register(flutterEngine, this)
        AudioDecode.register(flutterEngine.dartExecutor.binaryMessenger)
        SpeechRuntime.register(flutterEngine.dartExecutor.binaryMessenger, this) { this }
        SystemRegion.register(flutterEngine.dartExecutor.binaryMessenger)
        FileExport.register(flutterEngine.dartExecutor.binaryMessenger) { this }
        pendingLaunch = takeLaunchName(intent)
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
     * The Storage Access Framework's picker answering, on its way past the
     * plugins that also watch for one. [FileExport] owns exactly one request
     * code and ignores everything else.
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        FileExport.handleResult(requestCode, resultCode, data)
    }

    /**
     * A tap on a widget while the app is already running.
     *
     * Android delivers this before the activity resumes, and the Dart side
     * asks again on every resume — so a Dictate or a Capture that arrives at
     * an app already in the background still gets done. Write needs nothing
     * further: the app is on the note the widget would have opened, and
     * resuming is what puts the caret back at the end of it.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pendingLaunch = takeLaunchName(intent) ?: pendingLaunch
    }

    /**
     * Consumes the widget action from the Activity intent itself as well as
     * from [pendingLaunch]. Android may recreate this Activity while its photo
     * picker is open; leaving the action on the base intent would make that
     * reconstruction look like a second Capture tap and reopen the camera over
     * the photo being returned.
     */
    private fun takeLaunchName(intent: Intent?): String? {
        val launchIntent = intent ?: return null
        val name = QuickAction.ofIntentAction(launchIntent.action)?.launchName ?: return null
        launchIntent.action = null
        return name
    }

    companion object {
        private const val CHANNEL = "kapynotes/quick_capture"
    }
}
