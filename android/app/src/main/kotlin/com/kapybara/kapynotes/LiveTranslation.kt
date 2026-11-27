package com.kapybara.kapynotes

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import android.view.translation.TranslationCapability
import android.view.translation.TranslationContext
import android.view.translation.TranslationManager
import android.view.translation.TranslationRequest
import android.view.translation.TranslationRequestValue
import android.view.translation.TranslationResponse
import android.view.translation.TranslationResponseValue
import android.view.translation.TranslationSpec
import android.view.translation.Translator
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * ML Kit's translator, from the `translation_runtime` module Google Play
 * delivers on demand: see MlKitTranslationPack there. An interface the base
 * app owns, so that nothing of ML Kit's is in the base, and the module is
 * found by name once it is loadable.
 *
 * Every callback comes on the main thread. Never logs what it translates.
 */
interface OnDeviceTranslationPack {
    /** Of [languages], those whose models aren't on this phone yet; null when ML Kit can't say. */
    fun missing(languages: List<String>, done: (List<String>?) -> Unit)

    /** Fetches both languages' models, on Wi-Fi only if [wifiOnly]. */
    fun download(from: String, to: String, wifiOnly: Boolean, done: (Boolean) -> Unit)

    fun remove(language: String, done: () -> Unit)

    /** A translator for a pair whose models are on the phone, or null. */
    fun open(from: String, to: String): PhraseTranslator?
}

/** Either engine, as the session uses it: one text at a time. */
interface PhraseTranslator {
    /** Null when the engine could not translate it. */
    fun translate(text: String, done: (String?) -> Unit)

    fun close()
}

/**
 * The `kapynotes/live_translation` channels: lib/speech/live_translation.dart.
 *
 * Live translation on Android 13 and later, entirely on the phone. The words
 * are heard by the phone's own on-device recogniser, fed through
 * [RecognizerIntent.EXTRA_AUDIO_SOURCE] from the session's own recording
 * ([LiveCapture]), so the recogniser never opens the microphone itself. They
 * are translated by the system's on-device translator where it covers the
 * pair, and otherwise by ML Kit, whose code Google Play adds only when
 * somebody turns this on ([OnDeviceTranslationPack]).
 *
 * Registering costs nothing: no recogniser, translator, module, microphone
 * or thread exists until Dart calls a method that needs one, and a person
 * who never turns live translation on never makes such a call. Below API 33
 * every method answers that it can't, rather than throwing.
 *
 * Nothing heard or translated is ever logged.
 */
class LiveTranslation private constructor(
    private val context: Context,
    private val activity: Activity,
    private val channel: MethodChannel,
    private val events: EventChannel,
) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var session: Session? = null
    private var preparing = false
    private var askingMicrophone: ((Boolean) -> Unit)? = null
    private var pack: OnDeviceTranslationPack? = null

    /** The system translator's capability query is a blocking call into another process. */
    private val worker: ExecutorService by lazy { Executors.newSingleThreadExecutor() }
    private val splitInstall: SplitInstallManager by lazy { SplitInstallManagerFactory.create(context) }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            unsupported(call.method, result)
            return
        }
        val from = call.argument<String>("from")?.lowercase()
        val to = call.argument<String>("to")?.lowercase()
        when (call.method) {
            "availability" -> result.success(if (SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) "ready" else "unsupported")
            "languages" -> languages(result)
            "pairStatus" -> if (from == null || to == null) result.success(mapOf("status" to "unsupported")) else pairStatus(from, to, result)
            "prepare" -> if (from == null || to == null) {
                result.success("unsupported")
            } else {
                prepare(from, to, call.argument<Boolean>("wifiOnly") ?: true, result)
            }
            "remove" -> remove(call.argument<String>("language")?.lowercase(), result)
            "translate" -> translate(from, to, call.argument<List<String>>("texts"), result)
            "start" -> start(from, to, call.argument<String>("path"), result)
            "pause" -> {
                session?.pause()
                result.success(null)
            }
            "resume" -> {
                session?.resume()
                result.success(null)
            }
            "stop" -> session?.stop(result) ?: result.success(mapOf("path" to null))
            else -> result.notImplemented()
        }
    }

    private fun unsupported(method: String, result: MethodChannel.Result) {
        when (method) {
            "availability", "prepare" -> result.success("unsupported")
            "languages" -> result.success(mapOf("spoken" to emptyList<String>(), "targets" to emptyList<String>(), "names" to emptyMap<String, Any>()))
            "pairStatus" -> result.success(mapOf("status" to "unsupported"))
            "remove", "pause", "resume" -> result.success(null)
            "translate" -> result.error("unsupported", "This phone can't translate on the device.", null)
            "start" -> result.error("unavailable", "Live translation needs Android 13 or later.", null)
            "stop" -> result.success(mapOf("path" to null))
            else -> result.notImplemented()
        }
    }

    // Languages

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun languages(result: MethodChannel.Result) {
        speechSupport { support ->
            val spoken = support?.let { (it.installedOnDeviceLanguages + it.supportedOnDeviceLanguages + it.pendingOnDeviceLanguages).map { tag -> languageOf(tag) }.toSortedSet() } ?: sortedSetOf<String>()
            systemCapabilities { capabilities ->
                val targets = capabilities
                    .filter { it.state != TranslationCapability.STATE_NOT_AVAILABLE }
                    .map { normalise(it.targetSpec.locale.language) }
                    .toSortedSet()
                targets.addAll(ML_KIT_LANGUAGES)
                result.success(
                    mapOf(
                        "spoken" to spoken.toList(),
                        "targets" to targets.toList(),
                        "names" to (spoken + targets).associateWith { code -> names(code) },
                    ),
                )
            }
        }
    }

    private enum class Readiness { INSTALLED, DOWNLOADABLE, UNSUPPORTED }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun pairStatus(from: String, to: String, result: MethodChannel.Result) {
        if (from == to || !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.success(mapOf("status" to "unsupported"))
            return
        }
        speechSupport { support ->
            val speech = speechReadiness(support, from)
            if (speech == Readiness.UNSUPPORTED) {
                result.success(mapOf("status" to "unsupported"))
                return@speechSupport
            }
            translationReadiness(from, to) { translation, bytes ->
                val status = when {
                    translation == Readiness.UNSUPPORTED -> "unsupported"
                    translation == Readiness.INSTALLED && speech == Readiness.INSTALLED -> "installed"
                    else -> "downloadable"
                }
                result.success(mapOf("status" to status, "bytes" to bytes))
            }
        }
    }

    /**
     * Whether the pair can be translated on this phone. The system's
     * translator counts only when it is on the phone already: Android has
     * no call that asks it to fetch a language, so a pair it could only
     * download goes to ML Kit, which can. [done]'s bytes are ML Kit's
     * download, about 30 MB a language by Google's own figure; ML Kit says
     * nothing of a model's size before or after, so an installed pair's size
     * is unknown.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun translationReadiness(from: String, to: String, done: (Readiness, Long?) -> Unit) {
        systemCapabilities { capabilities ->
            when {
                systemPair(capabilities, from, to) != null -> done(Readiness.INSTALLED, null)
                from !in ML_KIT_LANGUAGES || to !in ML_KIT_LANGUAGES -> done(Readiness.UNSUPPORTED, null)
                else -> {
                    val loaded = loadPack()
                    if (loaded == null) {
                        done(Readiness.DOWNLOADABLE, ML_KIT_MODEL_BYTES * 2)
                    } else {
                        loaded.missing(listOf(from, to)) { missing ->
                            when {
                                missing == null -> done(Readiness.DOWNLOADABLE, ML_KIT_MODEL_BYTES * 2)
                                missing.isEmpty() -> done(Readiness.INSTALLED, null)
                                else -> done(Readiness.DOWNLOADABLE, ML_KIT_MODEL_BYTES * missing.size)
                            }
                        }
                    }
                }
            }
        }
    }

    // Prepare and remove

    /**
     * The microphone first, then the recogniser's language, then the
     * translator's. Answers once, when everything is on the phone or
     * something has said no.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun prepare(from: String, to: String, wifiOnly: Boolean, result: MethodChannel.Result) {
        if (preparing) {
            result.success("declined")
            return
        }
        if (from == to || !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.success("unsupported")
            return
        }
        preparing = true
        val answer = { outcome: String ->
            preparing = false
            result.success(outcome)
        }
        askMicrophone { granted ->
            if (!granted) return@askMicrophone answer("denied")
            askSpeechSupport { support, recognizer ->
                val tag = bestTag(support, from)
                if (recognizer != null && tag != null && speechReadiness(support, from) == Readiness.DOWNLOADABLE) {
                    return@askSpeechSupport downloadSpeech(tag, recognizer) { fetched ->
                        if (fetched) prepareTranslation(from, to, wifiOnly, answer) else answer("declined")
                    }
                }
                recognizer?.destroy()
                when (speechReadiness(support, from)) {
                    Readiness.INSTALLED -> prepareTranslation(from, to, wifiOnly, answer)
                    else -> answer("unsupported")
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun prepareTranslation(from: String, to: String, wifiOnly: Boolean, answer: (String) -> Unit) {
        systemCapabilities { capabilities ->
            when {
                systemPair(capabilities, from, to) != null -> answer("ready")
                from !in ML_KIT_LANGUAGES || to !in ML_KIT_LANGUAGES -> answer("unsupported")
                else -> installPack { loaded ->
                    if (loaded == null) {
                        answer("declined")
                    } else {
                        loaded.download(from, to, wifiOnly) { fetched -> answer(if (fetched) "ready" else "declined") }
                    }
                }
            }
        }
    }

    private fun remove(language: String?, result: MethodChannel.Result) {
        val loaded = if (language == null) null else loadPack()
        if (loaded == null || language == null) {
            result.success(null)
            return
        }
        loaded.remove(language) { result.success(null) }
    }

    private fun askMicrophone(done: (Boolean) -> Unit) {
        if (hasMicrophone()) return done(true)
        if (askingMicrophone != null) return done(false)
        askingMicrophone = done
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
    }

    /** The activity passing on the answer to [askMicrophone]'s question. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val done = askingMicrophone ?: return
        askingMicrophone = null
        done(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
    }

    private fun hasMicrophone(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    // Translate, outside a recording

    /**
     * Each of [texts] in turn, with the same engine a live session would
     * use. "unsupported" when the pair isn't on the phone: this never
     * downloads, and never touches the microphone.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun translate(from: String?, to: String?, texts: List<String>?, result: MethodChannel.Result) {
        if (from == null || to == null || texts == null || from == to) {
            result.error("unsupported", "This pair can't be translated on the device.", null)
            return
        }
        openTranslator(from, to) { translator ->
            if (translator == null) {
                result.error("unsupported", "This pair isn't on the device.", null)
                return@openTranslator
            }
            val translated = ArrayList<String>(texts.size)
            fun next() {
                if (translated.size == texts.size) {
                    translator.close()
                    result.success(translated)
                    return
                }
                val text = texts[translated.size]
                if (text.isBlank()) {
                    translated.add(text)
                    next()
                    return
                }
                translator.translate(text) { out ->
                    if (out == null) {
                        translator.close()
                        result.error("failed", "The translation failed.", null)
                    } else {
                        translated.add(out)
                        next()
                    }
                }
            }
            next()
        }
    }

    // Start, pause, resume, stop

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun start(from: String?, to: String?, path: String?, result: MethodChannel.Result) {
        when {
            session != null -> result.error("busy", "A live session is already running.", null)
            from == null || to == null || path == null -> result.error("unavailable", "Missing arguments.", null)
            !hasMicrophone() -> result.error("denied", "The microphone isn't allowed.", null)
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(context) -> result.error("unavailable", "No on-device recogniser.", null)
            else -> {
                val started = Session(from, to, File(path))
                if (!started.begin()) {
                    result.error("unavailable", "The microphone can't be opened.", null)
                    return
                }
                session = started
                result.success(null)
            }
        }
    }

    /**
     * One recording with live translation: its file, its recogniser and its
     * translator. The recording carries on whatever happens to the other
     * two; a recogniser or translator that can't go on sends one "error"
     * and is let go, while the audio and the levels keep coming.
     *
     * Main thread only, but for [feed], which the capture thread writes to.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private inner class Session(private val from: String, private val to: String, private val file: File) {
        private val capture = LiveCapture(
            file,
            context.mainExecutor,
            onPcm = { feed?.offer(it) },
            onLevel = { level -> main.post { send(mapOf("level" to level)) } },
            onLost = { main.post { interrupt() } },
        )

        @Volatile private var feed: Feed? = null
        private var source: ParcelFileDescriptor? = null
        private var recognizer: SpeechRecognizer? = null
        private var tag: String? = null
        private var translator: PhraseTranslator? = null
        private var awaitingTranslator = true
        private val untranslated = ArrayList<Pair<Int, String>>()
        private var translating = 0

        private var phrase = 0
        private var partial: String? = null
        private var listening = false
        private var errors = 0

        private var paused = false
        private var interrupted = false
        private var failed = false
        private var ended = false
        private var stopping: MethodChannel.Result? = null
        private var captured: Boolean? = null

        private val audio = context.getSystemService(AudioManager::class.java)
        private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAcceptsDelayedFocusGain(true)
            .setOnAudioFocusChangeListener({ change ->
                // As `record` does with AudioInterruptionMode.pause: any loss,
                // a call or another app's sound, pauses until Dart resumes.
                if (change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
                ) {
                    interrupt()
                }
            }, main)
            .build()

        private val relisten = Runnable { listen() }
        private val giveUpListening = Runnable { endListening() }
        private val giveUpTranslating = Runnable {
            translating = 0
            untranslated.clear()
            awaitingTranslator = false
            finishStop()
        }

        /** False when the microphone or the file can't be had. */
        fun begin(): Boolean {
            if (!capture.start()) return false
            audio?.requestAudioFocus(focus)
            openTranslator(from, to) { opened ->
                when {
                    failed || (ended && stopping == null) -> opened?.close()
                    opened == null -> fail("failed")
                    else -> {
                        translator = opened
                        awaitingTranslator = false
                        val waiting = untranslated.toList()
                        untranslated.clear()
                        for ((id, text) in waiting) translate(id, text)
                    }
                }
            }
            speechSupport { support ->
                if (ended || failed) return@speechSupport
                val best = bestTag(support, from)
                if (best == null || speechReadiness(support, from) != Readiness.INSTALLED) return@speechSupport fail("failed")
                tag = best
                recognizer = try {
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(context).apply { setRecognitionListener(listener) }
                } catch (error: RuntimeException) {
                    Log.w(TAG, "Could not create the on-device recogniser", error)
                    return@speechSupport fail("failed")
                }
                listen()
            }
            return true
        }

        fun pause() {
            if (ended || paused) return
            paused = true
            capture.pause()
            endPhrase()
        }

        /**
         * After Dart's own pause, or after an interruption. A microphone that
         * is still taken leaves the recording interrupted, and says so.
         */
        fun resume() {
            if (ended || (!paused && !interrupted)) return
            if (!capture.resume()) {
                paused = false
                if (!interrupted) {
                    interrupted = true
                    send(mapOf("interrupted" to true))
                }
                return
            }
            audio?.requestAudioFocus(focus)
            paused = false
            if (interrupted) {
                interrupted = false
                send(mapOf("interrupted" to false))
            }
            errors = 0
            listen()
        }

        /** A call, another app's sound or another app's recording took the microphone. */
        fun interrupt() {
            if (ended || paused || interrupted) return
            capture.pause()
            interrupted = true
            send(mapOf("interrupted" to true))
            endPhrase()
        }

        /**
         * Finishes the file, the phrase being heard and every translation
         * still owed, sends them, then "done", and only then answers: Dart
         * stops listening once it has the answer.
         */
        fun stop(result: MethodChannel.Result) {
            if (stopping != null) {
                result.error("busy", "Already stopping.", null)
                return
            }
            stopping = result
            ended = true
            main.removeCallbacks(relisten)
            audio?.abandonAudioFocusRequest(focus)
            worker.execute {
                val wrote = capture.stop()
                main.post {
                    captured = wrote
                    finishStop()
                }
            }
            if (listening) {
                endPhrase()
                main.postDelayed(giveUpListening, LISTEN_GRACE_MS)
            }
            main.postDelayed(giveUpTranslating, STOP_DEADLINE_MS)
            finishStop()
        }

        /** The engine going away with the activity: no one is left to answer. */
        fun close() {
            ended = true
            audio?.abandonAudioFocusRequest(focus)
            worker.execute { capture.stop() }
            release()
        }

        private fun finishStop() {
            val result = stopping ?: return
            val wrote = captured ?: return
            if (listening) return
            if (translating > 0 || (awaitingTranslator && untranslated.isNotEmpty())) return
            stopping = null
            release()
            send(mapOf("done" to true))
            if (session === this) session = null
            if (!wrote) file.delete()
            result.success(mapOf("path" to if (wrote) file.path else null))
        }

        private fun release() {
            main.removeCallbacks(relisten)
            main.removeCallbacks(giveUpListening)
            main.removeCallbacks(giveUpTranslating)
            closeFeed()
            recognizer?.destroy()
            recognizer = null
            translator?.close()
            translator = null
            if (session === this) session = null
        }

        private fun fail(code: String) {
            if (failed) return
            failed = true
            send(mapOf("error" to code))
            listening = false
            translating = 0
            untranslated.clear()
            awaitingTranslator = false
            closeFeed()
            recognizer?.destroy()
            recognizer = null
            translator?.close()
            translator = null
            finishStop()
        }

        // Hearing

        /**
         * One utterance: a fresh pipe, read by the recogniser until it hears
         * the end of speech, then [next] starts the next. The recogniser's
         * own process holds a duplicate of [source] from the moment it is
         * ready, so ours is closed then, and the recogniser closing its copy
         * is what ends [feed]'s writes.
         */
        private fun listen() {
            val current = recognizer ?: return
            if (failed || ended || paused || interrupted || listening) return
            val pipe = try {
                ParcelFileDescriptor.createPipe()
            } catch (error: IOException) {
                Log.w(TAG, "Could not open the recogniser's pipe", error)
                return fail("failed")
            }
            source = pipe[0]
            feed = try {
                Feed(pipe[1])
            } catch (error: ErrnoException) {
                Log.w(TAG, "Could not set up the recogniser's pipe", error)
                runCatching { pipe[1].close() }
                closeSource()
                return fail("failed")
            }
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, LiveCapture.RATE)
            listening = true
            current.startListening(intent)
        }

        /** Ends the utterance being heard: no more audio, and the recogniser's last word on it. */
        private fun endPhrase() {
            main.removeCallbacks(relisten)
            if (!listening) return
            closeFeed()
            recognizer?.stopListening()
        }

        private fun next(delayMs: Long = 0) {
            main.removeCallbacks(relisten)
            if (ended || paused || interrupted || failed) return
            main.postDelayed(relisten, delayMs)
        }

        private fun endListening() {
            if (!listening) return
            listening = false
            complete(partial)
            closeFeed()
            finishStop()
        }

        private fun closeFeed() {
            feed?.close()
            feed = null
            closeSource()
        }

        private fun closeSource() {
            try {
                source?.close()
            } catch (error: IOException) {
                Log.w(TAG, "Could not close the recogniser's pipe", error)
            }
            source = null
        }

        private fun complete(text: String?) {
            partial = null
            if (text.isNullOrBlank() || failed) return
            val id = phrase++
            send(mapOf("id" to id, "heard" to text, "final" to true))
            translate(id, text)
        }

        private fun translate(id: Int, text: String) {
            val current = translator
            if (current == null) {
                if (awaitingTranslator) untranslated.add(id to text)
                return
            }
            translating++
            current.translate(text) { out ->
                if (failed || translating == 0) return@translate
                translating--
                if (out != null) send(mapOf("id" to id, "translation" to out))
                finishStop()
            }
        }

        private val listener = object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = closeSource()
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onPartialResults(partialResults: Bundle?) {
                if (failed || !listening) return
                val text = heard(partialResults) ?: return
                if (text == partial) return
                partial = text
                errors = 0
                send(mapOf("id" to phrase, "heard" to text, "final" to false))
            }

            /** Often empty with an audio source: the last partial is the phrase then. */
            override fun onResults(results: Bundle?) {
                if (!listening) return
                listening = false
                main.removeCallbacks(giveUpListening)
                closeFeed()
                complete(heard(results) ?: partial)
                errors = 0
                next()
                finishStop()
            }

            override fun onError(error: Int) {
                if (!listening) return
                listening = false
                main.removeCallbacks(giveUpListening)
                closeFeed()
                complete(partial)
                when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> next()
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> fail("denied")
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> fail("failed")
                    else -> {
                        errors++
                        if (errors > MAX_ERRORS) fail("failed") else next(RETRY_MS * errors)
                    }
                }
                finishStop()
            }
        }
    }

    // Engines

    /** A translator for the pair if it is on the phone now: the system's first, then ML Kit's. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun openTranslator(from: String, to: String, done: (PhraseTranslator?) -> Unit) {
        systemCapabilities { capabilities ->
            val capability = systemPair(capabilities, from, to)
            if (capability != null) {
                systemTranslator(capability, done)
                return@systemCapabilities
            }
            val loaded = if (from in ML_KIT_LANGUAGES && to in ML_KIT_LANGUAGES) loadPack() else null
            if (loaded == null) return@systemCapabilities done(null)
            loaded.missing(listOf(from, to)) { missing ->
                done(if (missing != null && missing.isEmpty()) loaded.open(from, to) else null)
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun systemTranslator(capability: TranslationCapability, done: (PhraseTranslator?) -> Unit) {
        val manager = context.getSystemService(TranslationManager::class.java) ?: return done(null)
        val translation = TranslationContext.Builder(capability.sourceSpec, capability.targetSpec).build()
        try {
            manager.createOnDeviceTranslator(translation, context.mainExecutor) { translator: Translator? ->
                done(translator?.let { SystemTranslator(it) })
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Could not open the system translator", error)
            done(null)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private inner class SystemTranslator(private val translator: Translator) : PhraseTranslator {
        override fun translate(text: String, done: (String?) -> Unit) {
            val request = TranslationRequest.Builder()
                .setTranslationRequestValues(listOf(TranslationRequestValue.forText(text)))
                .build()
            try {
                translator.translate(request, null, context.mainExecutor) { response: TranslationResponse ->
                    if (response.isFinalResponse) {
                        val value = response.translationResponseValues.get(0)
                        val ok = response.translationStatus == TranslationResponse.TRANSLATION_STATUS_SUCCESS &&
                            value?.statusCode == TranslationResponseValue.STATUS_SUCCESS
                        done(if (ok) value?.text?.toString() else null)
                    }
                }
            } catch (error: IllegalStateException) {
                done(null)
            }
        }

        override fun close() {
            if (!translator.isDestroyed) translator.destroy()
        }
    }

    /**
     * Which pairs the system's translator has, on a worker thread because
     * Android answers it with a blocking call into its translation service.
     * Empty where the phone has no such service.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun systemCapabilities(done: (Set<TranslationCapability>) -> Unit) {
        worker.execute {
            val capabilities = try {
                context.getSystemService(TranslationManager::class.java)
                    ?.getOnDeviceTranslationCapabilities(TranslationSpec.DATA_FORMAT_TEXT, TranslationSpec.DATA_FORMAT_TEXT)
                    ?: emptySet()
            } catch (error: RuntimeException) {
                Log.w(TAG, "Could not ask the system translator what it has", error)
                emptySet()
            }
            main.post { done(capabilities) }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun systemPair(capabilities: Set<TranslationCapability>, from: String, to: String): TranslationCapability? =
        capabilities.firstOrNull {
            it.state == TranslationCapability.STATE_ON_DEVICE &&
                normalise(it.sourceSpec.locale.language) == from &&
                normalise(it.targetSpec.locale.language) == to
        }

    /**
     * What the on-device recogniser can hear, or null. A recogniser made
     * only to ask, and destroyed on the answer; one that never answers is
     * given up on.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun speechSupport(done: (RecognitionSupport?) -> Unit) =
        askSpeechSupport { support, recognizer ->
            recognizer?.destroy()
            done(support)
        }

    /**
     * [speechSupport], handing [done] the recogniser that asked, still
     * open, for the caller to destroy. Destroying it lets the system tear
     * the recognition service down, and a recogniser made a moment later
     * then loses its connection with ERROR_SERVER_DISCONNECTED, so
     * [prepare] downloads with this one instead.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun askSpeechSupport(done: (RecognitionSupport?, SpeechRecognizer?) -> Unit) {
        val recognizer = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (error: RuntimeException) {
            Log.w(TAG, "No on-device recogniser to ask", error)
            return done(null, null)
        }
        var answered = false
        lateinit var timeout: Runnable
        val answer = { support: RecognitionSupport? ->
            if (!answered) {
                answered = true
                main.removeCallbacks(timeout)
                done(support, recognizer)
            }
        }
        timeout = Runnable { answer(null) }
        main.postDelayed(timeout, SUPPORT_TIMEOUT_MS)
        recognizer.checkRecognitionSupport(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
            context.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(recognitionSupport: RecognitionSupport) = answer(recognitionSupport)
                override fun onError(error: Int) = answer(null)
            },
        )
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun speechReadiness(support: RecognitionSupport?, code: String): Readiness = when {
        support == null -> Readiness.UNSUPPORTED
        support.installedOnDeviceLanguages.any { languageOf(it) == code } -> Readiness.INSTALLED
        (support.supportedOnDeviceLanguages + support.pendingOnDeviceLanguages).any { languageOf(it) == code } -> Readiness.DOWNLOADABLE
        else -> Readiness.UNSUPPORTED
    }

    /**
     * The recogniser's tag for [code]: one already on the phone before one
     * it would have to fetch, and the phone's own region where it has it, so
     * "en" on a phone set to English (India) hears en-IN.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun bestTag(support: RecognitionSupport?, code: String): String? {
        support ?: return null
        val region = Locale.getDefault().country
        for (tags in listOf(support.installedOnDeviceLanguages, support.supportedOnDeviceLanguages + support.pendingOnDeviceLanguages)) {
            val matching = tags.filter { languageOf(it) == code }
            if (matching.isEmpty()) continue
            return matching.firstOrNull { Locale.forLanguageTag(it).country == region } ?: matching.first()
        }
        return null
    }

    /**
     * Asks the system to fetch the recogniser's language. Android 14 says
     * when it is done; on 13 there is no answer, so the support is asked
     * again until the language shows up. A download the system only
     * schedules, for Wi-Fi or a charger, counts as not done. Through
     * [asked], the recogniser that asked what it could hear, which this
     * destroys; a download that lost its connection is asked once more.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun downloadSpeech(tag: String, asked: SpeechRecognizer, done: (Boolean) -> Unit) {
        var recognizer = asked
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
        val deadline = System.currentTimeMillis() + SPEECH_DOWNLOAD_LIMIT_MS
        var answered = false
        val answer = { fetched: Boolean ->
            if (!answered) {
                answered = true
                recognizer.destroy()
                done(fetched)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            main.postDelayed({ answer(false) }, SPEECH_DOWNLOAD_LIMIT_MS)
            recognizer.triggerModelDownload(
                intent,
                context.mainExecutor,
                object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) {}
                    override fun onSuccess() = answer(true)
                    override fun onScheduled() {
                        Log.i(TAG, "The recogniser's language download was only scheduled")
                        answer(false)
                    }

                    override fun onError(error: Int) {
                        if (error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED && recognizer === asked && !answered) {
                            Log.i(TAG, "The recogniser's language download lost its connection; asking once more")
                            recognizer = try {
                                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                            } catch (failure: RuntimeException) {
                                Log.w(TAG, "No on-device recogniser to ask again", failure)
                                return answer(false)
                            }
                            recognizer.triggerModelDownload(intent, context.mainExecutor, this)
                            asked.destroy()
                            return
                        }
                        Log.w(TAG, "The recogniser's language download failed: error $error")
                        answer(false)
                    }
                },
            )
            return
        }
        recognizer.triggerModelDownload(intent)
        val language = languageOf(tag)
        fun poll() {
            speechSupport { support ->
                when {
                    speechReadiness(support, language) == Readiness.INSTALLED -> answer(true)
                    System.currentTimeMillis() > deadline || speechReadiness(support, language) == Readiness.UNSUPPORTED -> answer(false)
                    else -> main.postDelayed({ poll() }, SPEECH_DOWNLOAD_POLL_MS)
                }
            }
        }
        poll()
    }

    /**
     * ML Kit's half, if this process can load it now. The same test as
     * [SpeechRuntime]'s: a module Play delivered a moment ago is loadable
     * only once [SplitCompat] has been told, and a build that never came
     * from Play has no module at all.
     */
    private fun loadPack(): OnDeviceTranslationPack? {
        pack?.let { return it }
        SplitCompat.install(context)
        return try {
            (Class.forName(PACK_CLASS, true, context.classLoader)
                .getConstructor(Context::class.java)
                .newInstance(context) as OnDeviceTranslationPack)
                .also { pack = it }
        } catch (error: Exception) {
            Log.i(TAG, "translation runtime not loadable: ${error.javaClass.simpleName}")
            null
        } catch (error: LinkageError) {
            Log.i(TAG, "translation runtime not loadable: ${error.javaClass.simpleName}")
            null
        }
    }

    /**
     * Asks Play for the module, as [SpeechRuntime] does for the speech
     * engines, with Play's own size question over the activity when it has
     * one. Play has no Wi-Fi-only request; its question is where mobile data
     * is asked about.
     */
    private fun installPack(done: (OnDeviceTranslationPack?) -> Unit) {
        loadPack()?.let { return done(it) }
        val manager = splitInstall
        var sessionId = 0
        var answered = false
        lateinit var listener: SplitInstallStateUpdatedListener
        val answer = { loaded: OnDeviceTranslationPack? ->
            if (!answered) {
                answered = true
                manager.unregisterListener(listener)
                done(loaded)
            }
        }
        listener = SplitInstallStateUpdatedListener { state ->
            if (state.sessionId() != sessionId) return@SplitInstallStateUpdatedListener
            when (state.status()) {
                SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION ->
                    manager.startConfirmationDialogForResult(state, activity, CONFIRMATION_REQUEST)
                SplitInstallSessionStatus.INSTALLED -> answer(loadPack())
                SplitInstallSessionStatus.FAILED, SplitInstallSessionStatus.CANCELED -> answer(null)
                else -> {}
            }
        }
        manager.registerListener(listener)
        manager.startInstall(SplitInstallRequest.newBuilder().addModule(MODULE).build())
            .addOnSuccessListener { id ->
                sessionId = id
                // Already installed: Play answers at once, with no session.
                if (id == 0) answer(loadPack())
            }
            .addOnFailureListener { error ->
                Log.w(TAG, "Google Play could not add the translation runtime", error)
                answer(null)
            }
    }

    private fun send(event: Map<String, Any?>) {
        sink?.success(event)
    }

    fun close() {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) session?.close()
        session = null
        sink = null
        askingMicrophone = null
    }

    /**
     * Audio for one utterance, written into the recogniser's pipe as the
     * capture thread hands it over. Non-blocking: a recogniser that has
     * stopped reading would otherwise stall the recording itself, so a tenth
     * of a second it has no room for is dropped. Each write is 3,200 bytes,
     * under the pipe's atomic limit, so it goes in whole or not at all.
     * Synchronized so that the descriptor can't be closed, and its number
     * reused, in the middle of a write.
     */
    private class Feed(private val pipe: ParcelFileDescriptor) {
        private var open = true

        init {
            Os.fcntlInt(pipe.fileDescriptor, OsConstants.F_SETFL, OsConstants.O_NONBLOCK)
        }

        @Synchronized
        fun offer(chunk: ByteArray) {
            if (!open) return
            try {
                Os.write(pipe.fileDescriptor, chunk, 0, chunk.size)
            } catch (error: ErrnoException) {
                // EAGAIN: full for now. Anything else, EPIPE above all, means
                // the recogniser has closed its end and the utterance is over.
                if (error.errno != OsConstants.EAGAIN) open = false
            } catch (error: InterruptedIOException) {
                open = false
            }
        }

        @Synchronized
        fun close() {
            open = false
            try {
                pipe.close()
            } catch (error: IOException) {
                Log.w(TAG, "Could not close the recogniser's pipe", error)
            }
        }
    }

    companion object {
        private const val TAG = "KapyNotes"
        private const val CHANNEL = "kapynotes/live_translation"
        private const val EVENTS = "kapynotes/live_translation/phrases"
        const val MODULE = "translation_runtime"
        private const val PACK_CLASS = "com.kapybara.kapynotes.translation.MlKitTranslationPack"
        private const val PERMISSION_REQUEST = 0x4C54
        private const val CONFIRMATION_REQUEST = 7302

        /** Google's own figure for one ML Kit language model; ML Kit has no call that says. */
        private const val ML_KIT_MODEL_BYTES = 30L * 1024 * 1024

        /** TranslateLanguage.getAllLanguages(), kept here so the base needs none of ML Kit to list them. */
        private val ML_KIT_LANGUAGES = setOf(
            "af", "ar", "be", "bg", "bn", "ca", "cs", "cy", "da", "de",
            "el", "en", "eo", "es", "et", "fa", "fi", "fr", "ga", "gl",
            "gu", "he", "hi", "hr", "ht", "hu", "id", "is", "it", "ja",
            "ka", "kn", "ko", "lt", "lv", "mk", "mr", "ms", "mt", "nl",
            "no", "pl", "pt", "ro", "ru", "sk", "sl", "sq", "sv", "sw",
            "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
        )

        private const val SUPPORT_TIMEOUT_MS = 5_000L
        private const val SPEECH_DOWNLOAD_LIMIT_MS = 10 * 60_000L
        private const val SPEECH_DOWNLOAD_POLL_MS = 3_000L
        private const val LISTEN_GRACE_MS = 2_000L
        private const val STOP_DEADLINE_MS = 5_000L
        private const val MAX_ERRORS = 5
        private const val RETRY_MS = 500L

        fun register(activity: Activity, messenger: BinaryMessenger): LiveTranslation {
            val channel = MethodChannel(messenger, CHANNEL)
            val events = EventChannel(messenger, EVENTS)
            val live = LiveTranslation(activity.applicationContext, activity, channel, events)
            channel.setMethodCallHandler(live::handle)
            events.setStreamHandler(live)
            return live
        }

        /** ISO-639-1, with Java's old codes for Hebrew, Indonesian and Yiddish brought up to date. */
        private fun normalise(code: String): String = when (val lower = code.lowercase(Locale.ROOT)) {
            "iw" -> "he"
            "in" -> "id"
            "ji" -> "yi"
            else -> lower
        }

        private fun languageOf(tag: String): String = normalise(Locale.forLanguageTag(tag).language)

        private fun heard(results: Bundle?): String? =
            results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }

        /** The language's name in English and in itself, as the picker lists it. */
        private fun names(code: String): Map<String, String> {
            val locale = Locale.forLanguageTag(code)
            return mapOf(
                "english" to capitalised(locale.getDisplayLanguage(Locale.ENGLISH), Locale.ENGLISH),
                "own" to capitalised(locale.getDisplayLanguage(locale), locale),
            )
        }

        private fun capitalised(name: String, locale: Locale): String =
            name.replaceFirstChar { if (it.isLowerCase()) it.titlecase(locale) else it.toString() }
    }
}
