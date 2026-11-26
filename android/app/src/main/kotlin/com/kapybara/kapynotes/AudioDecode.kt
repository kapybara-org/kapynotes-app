package com.kapybara.kapynotes

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Turns an `.m4a` recording into the raw samples a speech model can read.
 *
 * Every recording this app makes is AAC; every speech model wants 16 kHz mono
 * PCM; nothing in Dart decodes AAC. Android already has a decoder in the box,
 * so this reaches for `MediaCodec` rather than shipping a second one.
 *
 * The common case does almost nothing: the app records mono AAC-LC at exactly
 * 16 kHz, so decoding is the whole job and the resampler below is a no-op. It
 * exists for the recordings that arrive by sync from a **Windows** machine,
 * where Media Foundation's encoder refuses anything under 44.1 kHz — a phone
 * has to be able to read a note its owner dictated on their laptop.
 *
 * The samples are written to a file rather than returned, because thirty
 * minutes is 57 MB and a method channel would hold the native buffer and the
 * Dart copy at the same time. Dart owns the file once this returns.
 *
 * The channel also goes the other way: `encode` writes a recording whose
 * noise has been removed, raw PCM by then, back into an `.m4a`.
 */
object AudioDecode {
  private const val CHANNEL = "kapynotes/audio_decode"

  /** Long enough that a stalled decoder is obvious, short enough to keep the loop responsive. */
  private const val TIMEOUT_US = 10_000L

  /** What the encoder is fed per pass: half a second at 16 kHz, and never the whole file. */
  private const val PCM_CHUNK_BYTES = 16 * 1024

  private val worker = Executors.newSingleThreadExecutor()

  fun register(messenger: BinaryMessenger): MethodChannel {
    val channel = MethodChannel(messenger, CHANNEL)
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "decode" -> {
          val path = call.argument<String>("path")
          val sampleRate = call.argument<Int>("sampleRate") ?: 16000
          if (path.isNullOrEmpty()) {
            result.error("arguments", "A recording is required.", null)
          } else {
            // Off the main thread: a thirty-minute recording is seconds of
            // work, and the UI it would otherwise block is the one showing
            // that the transcript is being made.
            worker.execute {
              try {
                val (out, frames) = run(path, sampleRate)
                val answer = mapOf("path" to out, "sampleRate" to sampleRate, "frames" to frames)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                  result.success(answer)
                }
              } catch (error: Throwable) {
                val message = error.message ?: "This recording could not be read."
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                  result.error("decode", message, null)
                }
              }
            }
          }
        }
        "encode" -> {
          val path = call.argument<String>("path")
          val destination = call.argument<String>("destination")
          val sampleRate = call.argument<Int>("sampleRate") ?: 16000
          val bitRate = call.argument<Int>("bitRate") ?: 48000
          if (path.isNullOrEmpty() || destination.isNullOrEmpty()) {
            result.error("arguments", "A recording is required.", null)
          } else {
            // Off the main thread for the reason decode is: thirty minutes of
            // audio is seconds of work.
            worker.execute {
              try {
                encode(path, destination, sampleRate, bitRate)
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                  result.success(null)
                }
              } catch (error: Throwable) {
                File(destination).delete()
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                  result.error("encode", "This recording could not be saved.", null)
                }
              }
            }
          }
        }
        else -> result.notImplemented()
      }
    }
    return channel
  }

  private fun run(path: String, targetRate: Int): Pair<String, Int> {
    val extractor = MediaExtractor()
    extractor.setDataSource(path)

    var track = -1
    var format: MediaFormat? = null
    for (index in 0 until extractor.trackCount) {
      val candidate = extractor.getTrackFormat(index)
      if (candidate.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
        track = index
        format = candidate
        break
      }
    }
    val source = format ?: throw IllegalStateException("This recording has no audio in it.")
    extractor.selectTrack(track)

    val sourceRate = source.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    val channels = source.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    val codec = MediaCodec.createDecoderByType(source.getString(MediaFormat.KEY_MIME)!!)
    codec.configure(source, null, null, 0)
    codec.start()

    val out = File.createTempFile("kapynotes-pcm-${UUID.randomUUID()}", ".pcm")
    val sink = BufferedOutputStream(FileOutputStream(out), 1 shl 16)
    val resampler = Resampler(sourceRate, targetRate)
    var frames = 0

    try {
      val info = MediaCodec.BufferInfo()
      var inputDone = false
      var outputDone = false

      while (!outputDone) {
        if (!inputDone) {
          val index = codec.dequeueInputBuffer(TIMEOUT_US)
          if (index >= 0) {
            val buffer = codec.getInputBuffer(index)!!
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
              codec.queueInputBuffer(
                index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }

        val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
        if (index >= 0) {
          if (info.size > 0) {
            val buffer = codec.getOutputBuffer(index)!!
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            val shorts = buffer.order(ByteOrder.nativeOrder()).asShortBuffer()
            val mono = downmix(shorts, channels)
            frames += resampler.process(mono, sink)
          }
          codec.releaseOutputBuffer(index, false)
          if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
        } else if (index == MediaCodec.INFO_TRY_AGAIN_LATER && inputDone) {
          // A decoder that has been told the input ended and still has
          // nothing to give has nothing left; looping here forever is the
          // classic way this goes wrong.
          continue
        }
      }
      frames += resampler.flush(sink)
    } finally {
      sink.flush()
      sink.close()
      runCatching { codec.stop() }
      codec.release()
      extractor.release()
    }

    if (frames == 0) {
      out.delete()
      throw IllegalStateException("This recording has no audio in it.")
    }
    return Pair(out.absolutePath, frames)
  }

  /**
   * Writes raw 16-bit mono PCM back out as the app's own kind of recording.
   *
   * The way back from [run], for a recording whose noise has been removed:
   * `MediaCodec`'s AAC-LC encoder into `MediaMuxer`'s MPEG-4 writer, so the
   * cleaned file is the same kind of `.m4a` the note had before. Dart owns the
   * rename into place; this only has to fail without leaving anything open.
   */
  private fun encode(path: String, destination: String, sampleRate: Int, bitRate: Int) {
    val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
    format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
    format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
    format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, PCM_CHUNK_BYTES)

    FileInputStream(path).use { input ->
      val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
      try {
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = MediaMuxer(destination, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
          val info = MediaCodec.BufferInfo()
          val chunk = ByteArray(PCM_CHUNK_BYTES)
          var queuedFrames = 0L
          var inputDone = false
          var track = -1
          while (true) {
            if (!inputDone) {
              val index = codec.dequeueInputBuffer(TIMEOUT_US)
              if (index >= 0) {
                val buffer = codec.getInputBuffer(index)!!
                buffer.clear()
                val read = input.read(chunk, 0, min(chunk.size, buffer.remaining()))
                // Each buffer is stamped with where it starts, which is what
                // the muxer turns into the recording's timing.
                val time = queuedFrames * 1_000_000L / sampleRate
                if (read <= 0) {
                  codec.queueInputBuffer(index, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                  inputDone = true
                } else {
                  buffer.put(chunk, 0, read)
                  codec.queueInputBuffer(index, 0, read, time, 0)
                  queuedFrames += read / 2
                }
              }
            }

            val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
              // The encoder's first answer is the format with the codec
              // setup in it, which is what the muxer needs to add the track.
              track = muxer.addTrack(codec.outputFormat)
              muxer.start()
              started = true
            } else if (index >= 0) {
              if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                val buffer = codec.getOutputBuffer(index)!!
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                muxer.writeSampleData(track, buffer, info)
              }
              codec.releaseOutputBuffer(index, false)
              if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
          }
          // Stopping is what writes the header; a failure here is a failed
          // save, so it is not swallowed like the one in `finally`.
          muxer.stop()
          started = false
        } finally {
          if (started) runCatching { muxer.stop() }
          muxer.release()
        }
      } finally {
        runCatching { codec.stop() }
        codec.release()
      }
    }
  }

  /**
   * Averages the channels.
   *
   * Averaging rather than taking the left channel: a stereo recording made
   * with one microphone off-centre would otherwise lose half its level, and a
   * quiet transcript is a worse transcript.
   */
  private fun downmix(samples: java.nio.ShortBuffer, channels: Int): ShortArray {
    val total = samples.remaining()
    if (channels <= 1) {
      val out = ShortArray(total)
      samples.get(out)
      return out
    }
    val frames = total / channels
    val out = ShortArray(frames)
    val scratch = ShortArray(total)
    samples.get(scratch)
    for (frame in 0 until frames) {
      var sum = 0
      for (channel in 0 until channels) sum += scratch[frame * channels + channel]
      out[frame] = (sum / channels).toShort()
    }
    return out
  }

  /**
   * Rate conversion with the anti-aliasing the obvious version leaves out.
   *
   * Dropping samples to go from 48 kHz to 16 kHz folds everything above
   * 8 kHz back down into the speech band as noise, which a recogniser hears
   * as a worse recording. So the signal is low-passed with a windowed-sinc
   * FIR first, then read at the new rate with linear interpolation between
   * filtered samples.
   *
   * A no-op when the rates match, which is every recording this app made
   * itself — the filter is only paid for by the ones that need it.
   */
  private class Resampler(private val sourceRate: Int, private val targetRate: Int) {
    companion object {
      /** How much is buffered before a write. One page of samples. */
      const val CHUNK = 1 shl 16
    }

    private val passthrough = sourceRate == targetRate
    private val ratio = sourceRate.toDouble() / targetRate.toDouble()

    /** Half-width of the kernel. 32 taps is inaudible here and cheap. */
    private val taps = if (passthrough) 0 else 32
    private val kernel: DoubleArray = if (passthrough) DoubleArray(0) else buildKernel()

    /** Carried across calls so a chunk boundary is not a discontinuity. */
    private val history = ArrayDeque<Short>()

    /** Where the next output sample falls between input samples, kept across chunks. */
    private var position = 0.0

    private fun buildKernel(): DoubleArray {
      // Cut at the lower of the two Nyquists, with a little margin so the
      // transition band does not eat the top of the speech.
      val cutoff = 0.45 * min(1.0, targetRate.toDouble() / sourceRate.toDouble())
      val width = taps * 2 + 1
      val out = DoubleArray(width)
      var sum = 0.0
      for (i in 0 until width) {
        val x = (i - taps).toDouble()
        val sinc = if (x == 0.0) 2.0 * cutoff else sin(2.0 * PI * cutoff * x) / (PI * x)
        // Hann window: no ringing worth hearing, and one line.
        val window = 0.5 - 0.5 * cos(2.0 * PI * i / (width - 1))
        out[i] = sinc * window
        sum += out[i]
      }
      for (i in 0 until width) out[i] /= sum
      return out
    }

    fun process(samples: ShortArray, sink: java.io.OutputStream): Int {
      if (passthrough) {
        val out = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) out.putShort(sample)
        sink.write(out.array())
        return samples.size
      }
      for (sample in samples) history.addLast(sample)
      return drain(sink)
    }

    fun flush(sink: java.io.OutputStream): Int {
      if (passthrough) return 0
      // Pad with silence so the last real samples get a full kernel and are
      // not quietly dropped at the end of every recording.
      repeat(taps * 2 + 1) { history.addLast(0) }
      return drain(sink)
    }

    private fun drain(sink: java.io.OutputStream): Int {
      val width = taps * 2 + 1
      val available = history.size
      // A kernel's worth is always left behind: the samples at the end of
      // this chunk need the start of the next one for their context, and
      // `flush` supplies silence in its place at the very end.
      if (available <= width) return 0

      val window = ShortArray(available)
      var index = 0
      for (sample in history) window[index++] = sample

      var written = 0
      var out = ByteBuffer.allocate(CHUNK).order(ByteOrder.LITTLE_ENDIAN)
      var consumed = 0.0
      var cursor = position
      while (cursor + width < available) {
        val base = cursor.toInt()
        val frac = cursor - base
        val left = filtered(window, base)
        val right = filtered(window, base + 1)
        val value = left + (right - left) * frac
        val clamped = value.roundToInt().coerceIn(-32768, 32767)
        if (out.remaining() < 2) {
          sink.write(out.array(), 0, out.position())
          out = ByteBuffer.allocate(CHUNK).order(ByteOrder.LITTLE_ENDIAN)
        }
        out.putShort(clamped.toShort())
        written++
        cursor += ratio
        consumed = cursor
      }
      if (out.position() > 0) sink.write(out.array(), 0, out.position())

      val drop = consumed.toInt()
      repeat(min(drop, history.size)) { history.removeFirst() }
      position = consumed - drop
      return written
    }

    private fun filtered(window: ShortArray, centre: Int): Double {
      var sum = 0.0
      for (i in kernel.indices) {
        val at = centre + i
        if (at >= 0 && at < window.size) sum += window[at] * kernel[i]
      }
      return sum
    }
  }
}
