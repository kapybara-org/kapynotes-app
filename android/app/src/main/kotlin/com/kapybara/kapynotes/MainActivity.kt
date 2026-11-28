package com.kapybara.kapynotes

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity behind the Flutter app, and the one question Dart asks the
 * platform on the way up: why am I open?
 *
 * The widgets are the only things that answer anything but "normally", and
 * they do so by naming their own action on the intent that starts this
 * activity — see [QuickAction] — and so does a recording's notification:
 * see [RecordingService]. The answer is handed over once and then
 * cleared, so that a later launch from the icon cannot inherit a tap on a
 * widget, and so that a Capture the app has already acted on does not open
 * the picker again the next time Dart asks.
 */
class MainActivity : FlutterFragmentActivity() {
    private var pendingLaunch: String? = null
    private var noteTitles: NoteTitles? = null
    private var contrastSetting: ContrastSetting? = null
    private var recordingControls: RecordingControls? = null
    private var liveTranslation: LiveTranslation? = null

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
        CameraSupport.register(flutterEngine.dartExecutor.binaryMessenger, this)
        StoreUpdate.register(flutterEngine.dartExecutor.binaryMessenger, this)
        contrastSetting = ContrastSetting.register(this, flutterEngine.dartExecutor.binaryMessenger)
        StatusBar.register(flutterEngine.dartExecutor.binaryMessenger, this)
        noteTitles = NoteTitles.register(flutterEngine.dartExecutor.binaryMessenger)
        FileExport.register(flutterEngine.dartExecutor.binaryMessenger) { this }
        recordingControls = RecordingControls.register(this, flutterEngine.dartExecutor.binaryMessenger)
        liveTranslation = LiveTranslation.register(this, flutterEngine.dartExecutor.binaryMessenger)
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
     * A cold start's widget action, handed to Dart as it starts rather than
     * asked for over [CHANNEL]. At that moment this thread is bringing up the
     * window and the keyboard, and an answer that waits for it can miss Dart's
     * deadline, which drops the action. Taken off the same intent as
     * [pendingLaunch], and called before [configureFlutterEngine], so the
     * channel never answers it a second time.
     */
    override fun getDartEntrypointArgs(): List<String> = listOfNotNull(takeLaunchName(intent))

    /**
     * A recreated activity (after process death, or with "Don't keep
     * activities") has already acted on the widget tap that started it, yet
     * it comes back with that tap's intent, and its restored Flutter fragment
     * comes back with the action from [getDartEntrypointArgs] in its
     * arguments. Dart would start again on either, so a Capture would reopen
     * the camera over the photo being returned and a Dictate would restart
     * without a tap. Both are cleared before `super.onCreate`, inside which
     * the restored fragment attaches, configures the engine and starts Dart.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState != null) {
            intent?.action = null
            supportFragmentManager.registerFragmentLifecycleCallbacks(
                object : FragmentManager.FragmentLifecycleCallbacks() {
                    override fun onFragmentPreAttached(
                        fm: FragmentManager,
                        f: Fragment,
                        context: Context,
                    ) {
                        if (f.tag != FLUTTER_FRAGMENT_TAG) return
                        f.arguments?.remove(DART_ENTRYPOINT_ARGS)
                        fm.unregisterFragmentLifecycleCallbacks(this)
                    }
                },
                false,
            )
        }
        super.onCreate(savedInstanceState)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        noteTitles?.close()
        noteTitles = null
        contrastSetting?.close()
        contrastSetting = null
        recordingControls?.close()
        recordingControls = null
        liveTranslation?.close()
        liveTranslation = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Notifications, asked for by [RecordingControls] as somebody records,
     * and the microphone, asked for by [LiveTranslation] as somebody turns
     * it on.
     */
    @Deprecated("Deprecated in FragmentActivity")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        recordingControls?.onPermissionResult(requestCode)
        liveTranslation?.onPermissionResult(requestCode, grantResults)
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
        val name =
            if (launchIntent.action == RecordingService.ACTION_OPEN) {
                "recording"
            } else {
                QuickAction.ofIntentAction(launchIntent.action)?.launchName
            } ?: return null
        launchIntent.action = null
        return name
    }

    companion object {
        private const val CHANNEL = "kapynotes/quick_capture"

        /** FlutterFragmentActivity's tag for its fragment, private there. */
        private const val FLUTTER_FRAGMENT_TAG = "flutter_fragment"

        /** FlutterFragment's argument key for Dart's arguments, protected there. */
        private const val DART_ENTRYPOINT_ARGS = "dart_entrypoint_args"
    }
}
