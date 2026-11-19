package com.kapybara.kapynotes

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Feature
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * Backs the `kapynotes/titles` channel: a note's title, written by Gemini
 * Nano on the device through ML Kit's GenAI Prompt API.
 *
 * Gemini Nano lives in the AICore system app, not in this one, and only some
 * devices have it. `availability` says which of four things is true and never
 * starts the model download: that is the person's call to make, not a title's.
 * The library's own minimum is Android 8 (API 26), above this app's, so every
 * call into it sits behind a runtime check and older phones answer
 * "unavailable".
 *
 * One title is made at a time. A second request while one runs is refused
 * with "busy" rather than queued, since a title that arrives late is for a
 * note the person has already moved on from. Neither the prompt nor the
 * output is ever logged: both are the person's own words. A failure logs
 * the class of what was thrown and nothing else, since an exception's
 * message can quote the prompt.
 */
class NoteTitles private constructor(messenger: BinaryMessenger) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val main = Handler(Looper.getMainLooper())
  private val running = AtomicBoolean(false)
  private val channel = MethodChannel(messenger, CHANNEL)
  private var client: GenerativeModel? = null

  init {
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "availability" -> availability(result)
        "name" -> name(
          call.argument<String>("instructions"),
          call.argument<String>("prompt"),
          result,
        )
        else -> result.notImplemented()
      }
    }
  }

  /** Called when the engine goes: stops what is running and lets the model go. */
  fun close() {
    channel.setMethodCallHandler(null)
    scope.cancel()
    synchronized(this) {
      client?.close()
      client = null
    }
  }

  @Synchronized
  private fun model(): GenerativeModel = client ?: Generation.getClient().also { client = it }

  private fun availability(result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < MIN_SDK) return result.success("unavailable")
    scope.launch {
      val answer = try {
        when (model().checkStatus()) {
          FeatureStatus.AVAILABLE -> "available"
          FeatureStatus.DOWNLOADABLE -> "downloadable"
          FeatureStatus.DOWNLOADING -> "downloading"
          else -> "unavailable"
        }
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        Log.w(TAG, "availability failed: ${error.javaClass.name}")
        "unavailable"
      }
      main.post { result.success(answer) }
    }
  }

  private fun name(instructions: String?, prompt: String?, result: MethodChannel.Result) {
    if (instructions == null || prompt == null) {
      return result.error("failed", "A title needs instructions and a prompt.", null)
    }
    if (Build.VERSION.SDK_INT < MIN_SDK) {
      return result.error("unavailable", "Gemini Nano is not available here.", null)
    }
    if (!running.compareAndSet(false, true)) {
      return result.error("busy", "A title is already being made.", null)
    }
    scope.launch {
      var code = "failed"
      var message = "A title could not be made."
      var title: String? = null
      try {
        val model = model()
        if (model.checkStatus() != FeatureStatus.AVAILABLE) {
          code = "unavailable"
          message = "Gemini Nano is not available here."
        } else {
          title = withTimeout(TIMEOUT_MS) { generate(model, instructions, prompt) }
        }
      } catch (error: CancellationException) {
        if (error !is TimeoutCancellationException) throw error
        Log.w(TAG, "title timed out")
      } catch (error: Exception) {
        Log.w(TAG, "title failed: ${error.javaClass.name}")
      } finally {
        running.set(false)
      }
      main.post {
        if (title.isNullOrEmpty()) result.error(code, message, null) else result.success(title)
      }
    }
  }

  /**
   * The instructions go as the system instruction where the model takes one,
   * and ahead of the prompt in the same text where it does not. Low
   * temperature and a short ceiling: a title is a few words, and the model
   * should give the same few every time.
   */
  private suspend fun generate(model: GenerativeModel, instructions: String, prompt: String): String? {
    val init: GenerateContentRequest.Builder.() -> Unit = {
      temperature = TEMPERATURE
      maxOutputTokens = MAX_OUTPUT_TOKENS
    }
    val request = if (Feature.SYSTEM_PROMPT in model.getAvailableFeatures()) {
      generateContentRequest(SystemInstruction(instructions), TextPart(prompt), init)
    } else {
      generateContentRequest(TextPart("$instructions\n\n$prompt"), init)
    }
    return model.generateContent(request).candidates.firstOrNull()?.text?.trim()
  }

  companion object {
    private const val CHANNEL = "kapynotes/titles"
    private const val TAG = "NoteTitles"
    private const val MIN_SDK = Build.VERSION_CODES.O
    private const val TIMEOUT_MS = 60_000L
    private const val TEMPERATURE = 0.1f
    private const val MAX_OUTPUT_TOKENS = 32

    fun register(messenger: BinaryMessenger): NoteTitles = NoteTitles(messenger)
  }
}
