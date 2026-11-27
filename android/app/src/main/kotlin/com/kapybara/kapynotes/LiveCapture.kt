package com.kapybara.kapynotes

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.Executor
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.abs
import kotlin.math.log10

/**
 * The recording a live-translation session makes, in place of `record`'s.
 *
 * Android lets only one capture of the microphone be trusted at a time, and
 * the recogniser has to hear the same samples the note keeps. So with live
 * translation on, this records: one [AudioRecord] at 16 kHz mono, encoded by
 * [MediaCodec] to the same 48 kbps AAC-LC `record` makes, and written to
 * [file] as ADTS, a frame at a time, the moment each frame exists. That is
 * the file lib/audio/voice_recorder.dart writes on this platform, beside the
 * `.m4a` it will become, so `finishAdtsRecording` and the recovery after a
 * kill read it without knowing which of the two wrote it.
 *
 * Every frame is written whole in one call, header and all, so a kill leaves
 * at most the frame in flight cut short, which is where `mp4FromAdts` stops
 * reading. Pausing stops and releases the microphone, so Android's privacy
 * indicator goes out with it; the encoder and the file stay open, and the
 * frames after a resume carry on in the same file.
 *
 * The samples go on to [onPcm] and their peak to [onLevel] on the capture
 * thread. [onLost] is called, from that thread or from [callbacks], when the
 * microphone stops for a reason nobody here asked for: the audio server
 * restarting, or another app taking the microphone and Android silencing
 * this one. The capture is then paused, waiting for [resume].
 */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
class LiveCapture(
    private val file: File,
    private val callbacks: Executor,
    private val onPcm: (ByteArray) -> Unit,
    private val onLevel: (Double) -> Unit,
    private val onLost: () -> Unit,
) {
    private enum class State { RUNNING, PAUSED, STOPPED }

    private val lock = ReentrantLock()
    private val resumed = lock.newCondition()
    private var state = State.STOPPED
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    // The capture thread's own, once it has started.
    private var codec: MediaCodec? = null
    private var out: FileOutputStream? = null
    private var samples = 0L
    private var frames = 0

    private val silenced = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
            val mine = lock.withLock { record } ?: return
            if (configs.none { it.clientAudioSessionId == mine.audioSessionId && it.isClientSilenced }) return
            if (lose()) onLost()
        }
    }

    /**
     * Opens the file, the encoder and the microphone, and starts recording.
     * False, with nothing left on disk, when any of the three can't be had.
     * The caller has checked the microphone permission.
     */
    fun start(): Boolean {
        try {
            out = FileOutputStream(file)
            codec = newEncoder()
        } catch (error: Exception) {
            Log.w(TAG, "Could not open the live recording", error)
            closeOutput()
            file.delete()
            return false
        }
        val opened = lock.withLock {
            openMicrophone().also { if (it) state = State.RUNNING }
        }
        if (!opened) {
            closeOutput()
            file.delete()
            return false
        }
        thread = Thread(::capture, "kapynotes-live-capture").also { it.start() }
        return true
    }

    /** False when it was not recording. */
    fun pause(): Boolean {
        lock.withLock {
            if (state != State.RUNNING) return false
            state = State.PAUSED
            stopMicrophone()
            return true
        }
    }

    /**
     * Opens the microphone again and carries on in the same file. A fresh
     * [AudioRecord] every time, because the one that was lost to the audio
     * server can't be started again. False when the microphone is still
     * taken.
     */
    fun resume(): Boolean {
        lock.withLock {
            if (state != State.PAUSED) return state == State.RUNNING
            closeMicrophone()
            if (!openMicrophone()) return false
            state = State.RUNNING
            resumed.signalAll()
            return true
        }
    }

    /**
     * Ends the recording, flushing the encoder's last frames into the file.
     * True when the file holds at least one frame. Waits for the capture
     * thread, so it is called off the main thread.
     */
    fun stop(): Boolean {
        lock.withLock {
            state = State.STOPPED
            stopMicrophone()
            resumed.signalAll()
        }
        thread?.join()
        thread = null
        closeOutput()
        return frames > 0
    }

    /** Paused by the microphone going away; false when it wasn't running. */
    private fun lose(): Boolean {
        lock.withLock {
            if (state != State.RUNNING) return false
            state = State.PAUSED
            stopMicrophone()
            return true
        }
    }

    private fun capture() {
        val chunk = ByteArray(CHUNK_BYTES)
        val info = MediaCodec.BufferInfo()
        while (true) {
            val source = lock.withLock {
                if (state == State.PAUSED) {
                    closeMicrophone()
                    while (state == State.PAUSED) resumed.awaitUninterruptibly()
                }
                if (state == State.STOPPED) null else record
            } ?: break
            val read = source.read(chunk, 0, chunk.size)
            if (read < 0) {
                if (lose()) onLost()
                continue
            }
            if (read == 0) continue
            if (!encode(chunk, read, info)) {
                if (lose()) onLost()
                continue
            }
            onLevel(level(chunk, read))
            onPcm(chunk.copyOf(read))
        }
        lock.withLock { closeMicrophone() }
        finishEncoder(info)
    }

    /**
     * Hands the samples to the encoder and writes what comes out. An encoder
     * that fails is replaced once: ADTS frames stand alone, so a new one
     * carries on in the same file. False when that fails too, or when the
     * file can no longer be written.
     */
    private fun encode(pcm: ByteArray, length: Int, info: MediaCodec.BufferInfo): Boolean {
        repeat(2) {
            val encoder = codec ?: try {
                newEncoder().also { codec = it }
            } catch (error: Exception) {
                Log.w(TAG, "Could not restart the live recording's encoder", error)
                return false
            }
            try {
                var offset = 0
                while (offset < length) {
                    val index = encoder.dequeueInputBuffer(TIMEOUT_US)
                    if (index < 0) {
                        drain(encoder, info, endOfStream = false)
                        continue
                    }
                    val buffer = encoder.getInputBuffer(index)
                    var size = 0
                    if (buffer != null) {
                        buffer.clear()
                        size = minOf(buffer.remaining(), length - offset) and 1.inv()
                        buffer.put(pcm, offset, size)
                    }
                    encoder.queueInputBuffer(index, 0, size, samples * 1_000_000L / RATE, 0)
                    samples += size / 2
                    offset += size
                    if (size == 0) break
                }
                drain(encoder, info, endOfStream = false)
                return true
            } catch (error: IOException) {
                Log.w(TAG, "Could not write the live recording", error)
                return false
            } catch (error: IllegalStateException) {
                Log.w(TAG, "The live recording's encoder failed", error)
                release(encoder)
                codec = null
            }
        }
        return false
    }

    private fun drain(encoder: MediaCodec, info: MediaCodec.BufferInfo, endOfStream: Boolean) {
        val deadline = System.nanoTime() + END_WAIT_NS
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, if (endOfStream) TIMEOUT_US else 0)
            if (index >= 0) {
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    writeFrame(buffer, info.size)
                }
                encoder.releaseOutputBuffer(index, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
            } else if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream || System.nanoTime() > deadline) return
            }
        }
    }

    /**
     * One AAC frame behind the 7-byte ADTS header lib/audio/adts.dart reads:
     * MPEG-4, no checksum, AAC-LC, 16 kHz, one channel, one raw block.
     */
    private fun writeFrame(payload: ByteBuffer, size: Int) {
        val length = ADTS_HEADER + size
        val frame = ByteArray(length)
        frame[0] = 0xFF.toByte()
        frame[1] = 0xF1.toByte()
        frame[2] = (((AAC_LC - 1) shl 6) or (RATE_INDEX shl 2) or (CHANNELS shr 2)).toByte()
        frame[3] = (((CHANNELS and 3) shl 6) or (length shr 11)).toByte()
        frame[4] = ((length shr 3) and 0xFF).toByte()
        frame[5] = (((length and 7) shl 5) or 0x1F).toByte()
        frame[6] = 0xFC.toByte()
        payload.get(frame, ADTS_HEADER, size)
        (out ?: throw IOException("closed")).write(frame)
        frames++
    }

    private fun finishEncoder(info: MediaCodec.BufferInfo) {
        val encoder = codec ?: return
        codec = null
        try {
            val index = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (index >= 0) {
                encoder.queueInputBuffer(index, 0, 0, samples * 1_000_000L / RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                drain(encoder, info, endOfStream = true)
            }
        } catch (error: IOException) {
            Log.w(TAG, "Could not write the end of the live recording", error)
        } catch (error: IllegalStateException) {
            Log.w(TAG, "The live recording's encoder failed at the end", error)
        }
        release(encoder)
    }

    /** Under [lock]. */
    @SuppressLint("MissingPermission")
    private fun openMicrophone(): Boolean {
        val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) return false
        val created = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minimum, CHUNK_BYTES * 4),
            )
        } catch (error: RuntimeException) {
            Log.w(TAG, "Could not open the microphone", error)
            return false
        }
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            return false
        }
        created.registerAudioRecordingCallback(callbacks, silenced)
        try {
            created.startRecording()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Could not start the microphone", error)
        }
        if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            created.unregisterAudioRecordingCallback(silenced)
            created.release()
            return false
        }
        record = created
        return true
    }

    /** Under [lock]. Wakes a capture thread waiting in `read`. */
    private fun stopMicrophone() {
        try {
            record?.stop()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Could not stop the microphone", error)
        }
    }

    /** Under [lock], and only once no `read` can be waiting on it. */
    private fun closeMicrophone() {
        val current = record ?: return
        record = null
        current.unregisterAudioRecordingCallback(silenced)
        current.release()
    }

    private fun closeOutput() {
        codec?.let(::release)
        codec = null
        try {
            out?.close()
        } catch (error: IOException) {
            Log.w(TAG, "Could not close the live recording", error)
        }
        out = null
    }

    private fun release(encoder: MediaCodec) {
        try {
            encoder.stop()
        } catch (error: IllegalStateException) {
            // Never started, or already failed: release is all that is left.
        }
        encoder.release()
    }

    companion object {
        private const val TAG = "KapyNotes"

        const val RATE = 16000
        private const val CHANNELS = 1
        private const val BIT_RATE = 48000

        /** ADTS's index for 16 kHz, and its number for AAC-LC (object type 2). */
        private const val RATE_INDEX = 8
        private const val AAC_LC = 2
        private const val ADTS_HEADER = 7

        /** A tenth of a second of samples: one level, one write to the recogniser. */
        private const val CHUNK_BYTES = RATE / 10 * 2

        private const val TIMEOUT_US = 10_000L
        private const val END_WAIT_NS = 1_000_000_000L

        private fun newEncoder(): MediaCodec {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, CHUNK_BYTES)
            }
            val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            try {
                encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                encoder.start()
            } catch (error: RuntimeException) {
                encoder.release()
                throw error
            }
            return encoder
        }

        /** The loudest sample as dBFS, the way `record` measures it. */
        private fun level(pcm: ByteArray, length: Int): Double {
            var peak = 0
            var i = 0
            while (i + 1 < length) {
                val sample = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)).toShort().toInt()
                peak = maxOf(peak, abs(sample))
                i += 2
            }
            if (peak == 0) return -160.0
            return minOf(0.0, 20 * log10(peak / 32767.0))
        }
    }
}
