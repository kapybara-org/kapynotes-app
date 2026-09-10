package com.kapybara.kapynotes

import android.app.Activity
import android.content.Context
import android.util.Log
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallErrorCode
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The on-device speech engines' native code, fetched from Google Play when
 * somebody first asks for a local model.
 *
 * The libraries live in the `speech_runtime` dynamic feature module rather
 * than the base app, so a phone that only ever transcribes in the cloud never
 * downloads them. This is the runner half of `PlayRuntimePack` in Dart, and
 * the contract is small:
 *
 *   * `isInstalled` — can this process load the engines *now*. Not "does Play
 *     say the module is installed": a module that arrived a moment ago is not
 *     loadable until [SplitCompat] has been told about it, and a debug build
 *     made by `flutter run` has the libraries in the base and no module at
 *     all. Trying to load them is the one answer that is right in every case.
 *   * `install` — ask Play, report bytes as they arrive through `progress`
 *     calls back on the same channel, and answer when the code is loadable.
 *   * `cancel`, `remove` — hand the same requests on to Play.
 *
 * The libraries loaded here are loaded by name from Dart afterwards. Loading
 * them from Java first is what guarantees that works without a restart: a
 * library already in the process is found by its name from anywhere in it,
 * whatever the linker's search path happens to be.
 */
class SpeechRuntime private constructor(
    private val context: Context,
    private val activity: () -> Activity?,
    private val channel: MethodChannel,
) {
    private val manager: SplitInstallManager = SplitInstallManagerFactory.create(context)
    private var sessionId = 0
    private var pending: MethodChannel.Result? = null

    private val listener = SplitInstallStateUpdatedListener { state ->
        if (state.sessionId() != sessionId) return@SplitInstallStateUpdatedListener
        onState(state)
    }

    private fun isInstalled(): Boolean = loadable()

    private fun install(result: MethodChannel.Result) {
        if (loadable()) {
            result.success(null)
            return
        }
        if (pending != null) {
            result.error("busy", "The on-device engine is already being added.", null)
            return
        }
        pending = result
        manager.registerListener(listener)
        val request = SplitInstallRequest.newBuilder().addModule(MODULE).build()
        manager.startInstall(request)
            .addOnSuccessListener { id -> sessionId = id }
            .addOnFailureListener { error -> finish { it.error("failed", describe(error), null) } }
    }

    private fun onState(state: SplitInstallSessionState) {
        when (state.status()) {
            SplitInstallSessionStatus.DOWNLOADING, SplitInstallSessionStatus.DOWNLOADED,
            SplitInstallSessionStatus.INSTALLING -> {
                channel.invokeMethod(
                    "progress",
                    mapOf("received" to state.bytesDownloaded(), "total" to state.totalBytesToDownload()),
                )
            }
            SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> {
                // Play wants the user to agree to the size, on mobile data or
                // for a large module. Its own dialog, over our activity.
                val host = activity()
                if (host == null) {
                    finish { it.error("failed", "Google Play needs Kapy Notes on screen to ask about the download.", null) }
                } else {
                    manager.startConfirmationDialogForResult(state, host, CONFIRMATION_REQUEST)
                }
            }
            SplitInstallSessionStatus.INSTALLED -> {
                SplitCompat.install(context)
                if (loadable()) {
                    finish { it.success(null) }
                } else {
                    finish { it.error("restart", "The on-device engine was added. Quit and reopen Kapy Notes to use it.", null) }
                }
            }
            SplitInstallSessionStatus.FAILED -> finish { it.error("failed", describe(state.errorCode()), null) }
            SplitInstallSessionStatus.CANCELED -> finish { it.error("cancelled", "Cancelled.", null) }
            else -> {}
        }
    }

    private fun cancel(result: MethodChannel.Result) {
        if (pending == null) {
            result.success(null)
            return
        }
        manager.cancelInstall(sessionId)
            .addOnCompleteListener { result.success(null) }
    }

    private fun remove(result: MethodChannel.Result) {
        manager.deferredUninstall(listOf(MODULE))
            .addOnSuccessListener { result.success(null) }
            .addOnFailureListener { error -> result.error("failed", describe(error), null) }
    }

    private fun finish(answer: (MethodChannel.Result) -> Unit) {
        val result = pending ?: return
        pending = null
        sessionId = 0
        manager.unregisterListener(listener)
        answer(result)
    }

    /**
     * Whether the engines' code can be loaded by this process.
     *
     * Only the two libraries Parakeet needs are loaded here. LiteRT-LM is a
     * further 26 MB that `flutter_gemma` opens for itself on the first
     * summary, and by then the module's directory is on the linker path
     * (SplitCompat in this session, the installer's own doing after a
     * restart) — so it will find its own companions the same way these were
     * found. Loading twice is a reference count, not a second copy.
     */
    private fun loadable(): Boolean {
        SplitCompat.install(context)
        return try {
            for (library in PROBE_LIBRARIES) System.loadLibrary(library)
            true
        } catch (error: UnsatisfiedLinkError) {
            Log.i(TAG, "speech runtime not loadable: ${error.message}")
            false
        }
    }

    private fun describe(error: Exception): String {
        val code = (error as? com.google.android.play.core.splitinstall.SplitInstallException)?.errorCode
            ?: return error.localizedMessage ?: "Google Play could not add the on-device engine."
        return describe(code)
    }

    private fun describe(code: Int): String = when (code) {
        SplitInstallErrorCode.NETWORK_ERROR -> "Could not reach Google Play. Check your connection."
        SplitInstallErrorCode.INSUFFICIENT_STORAGE -> "Not enough room on this phone for the on-device engine."
        SplitInstallErrorCode.MODULE_UNAVAILABLE -> "Google Play does not offer the on-device engine for this phone."
        SplitInstallErrorCode.API_NOT_AVAILABLE, SplitInstallErrorCode.PLAY_STORE_NOT_FOUND,
        SplitInstallErrorCode.APP_NOT_OWNED ->
            "The on-device engine comes from Google Play, and this copy of Kapy Notes was not installed from there."
        SplitInstallErrorCode.ACCESS_DENIED -> "Google Play would not add the engine in the background. Try again with Kapy Notes open."
        SplitInstallErrorCode.ACTIVE_SESSIONS_LIMIT_EXCEEDED, SplitInstallErrorCode.INCOMPATIBLE_WITH_EXISTING_SESSION ->
            "Google Play is busy with another download. Try again in a moment."
        SplitInstallErrorCode.SESSION_NOT_FOUND -> "Google Play lost track of the download. Try again."
        else -> "Google Play could not add the on-device engine (error $code)."
    }

    companion object {
        private const val TAG = "SpeechRuntime"
        private const val CHANNEL = "kapynotes/speech_runtime"
        const val MODULE = "speech_runtime"
        private const val CONFIRMATION_REQUEST = 7301
        private val PROBE_LIBRARIES = listOf("onnxruntime", "sherpa-onnx-c-api")

        fun register(messenger: BinaryMessenger, context: Context, activity: () -> Activity?): SpeechRuntime {
            val channel = MethodChannel(messenger, CHANNEL)
            val runtime = SpeechRuntime(context.applicationContext, activity, channel)
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isInstalled" -> result.success(runtime.isInstalled())
                    "install" -> runtime.install(result)
                    "cancel" -> runtime.cancel(result)
                    "remove" -> runtime.remove(result)
                    else -> result.notImplemented()
                }
            }
            return runtime
        }
    }
}
