package com.kapybara.kapynotes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.text.format.DateUtils
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * A voice recording in progress, kept going while the app is out of sight.
 *
 * Android lets an app keep the microphone open with the screen off or another
 * app in front only from a foreground service of type microphone, and every
 * foreground service carries an ongoing notification. This one says how long
 * the recording is, counting up while it records, and offers Pause or Resume,
 * and Stop. It records nothing itself: `record` does that in the app, and
 * this exists exactly as long as the recording does.
 *
 * Declared with `stopWithTask`, so swiping the app away from Recents ends it
 * rather than leaving a notification behind with nothing under it. The
 * recorder closes its file on the way out, and the next launch puts it in its
 * note.
 */
class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when {
            action == ACTION_SHOW -> goForeground(startId)
            action != null && action in COMMANDS ->
                if (!RecordingControls.press(this, action)) stop(startId)
            // ACTION_HIDE, and a restart with no intent: there is no recording.
            else -> stop(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun goForeground(startId: Int) {
        try {
            val notification = notification(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            // Android 14 refuses one started without the microphone in use.
            // The recording carries on while the app is in front, which is
            // what it did before this service existed.
            Log.w(TAG, "Could not keep the recording going in the background", error)
            stop(startId)
        }
    }

    /**
     * Only as of [startId], so that a recording started a moment after the
     * last one stopped is shown rather than stopped with it.
     */
    private fun stop(startId: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    /**
     * How the recording looks from outside the app, as Dart last said.
     * [phrase] and [heard] are the latest finished live translation and what
     * was heard, and [live] says live translation is running; all three are
     * absent for a recording without it, which then looks exactly as it
     * always has.
     */
    private data class Shown(
        val startedAt: Long,
        val elapsedMs: Long,
        val paused: Boolean,
        val interrupted: Boolean,
        val phrase: String? = null,
        val heard: String? = null,
        val live: Boolean = false,
    )

    companion object {
        private const val TAG = "KapyNotes"

        /** A tap on the notification: lib/core/quick_capture.dart's `recording`. */
        const val ACTION_OPEN = "com.kapybara.kapynotes.OPEN_RECORDING"

        private const val ACTION_SHOW = "com.kapybara.kapynotes.recording.SHOW"
        private const val ACTION_HIDE = "com.kapybara.kapynotes.recording.HIDE"
        // Named as Dart names them: the method each press calls.
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_RESUME = "resume"
        private const val ACTION_STOP = "stop"
        private val COMMANDS = setOf(ACTION_PAUSE, ACTION_RESUME, ACTION_STOP)

        private const val CHANNEL_ID = "recording"

        /**
         * Notification.EXTRA_REQUEST_PROMOTED_ONGOING, Android 16's request
         * for a Live Update, by the value NotificationCompat also uses: set
         * as an extra so it needs no newer androidx.core than the plugins
         * bring.
         */
        private const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"
        private const val NOTIFICATION_ID = 0x5243

        /** Asked to start, and not since stopped. Main thread only. */
        private var running = false
        private var shown = Shown(0, 0, paused = false, interrupted = false)

        /**
         * Shows the recording, or brings what is shown up to date. Started
         * once, while somebody is pressing record; after that the notification
         * is only posted again, because a service cannot be started from the
         * background, and an interruption arrives there.
         */
        fun show(
            context: Context,
            elapsedMs: Long,
            paused: Boolean,
            interrupted: Boolean,
            phrase: String? = null,
            heard: String? = null,
            live: Boolean = false,
        ) {
            shown = Shown(System.currentTimeMillis() - elapsedMs, elapsedMs, paused, interrupted, phrase, heard, live)
            if (running) {
                try {
                    context.getSystemService(NotificationManager::class.java)
                        ?.notify(NOTIFICATION_ID, notification(context))
                } catch (error: SecurityException) {
                    Log.w(TAG, "Could not update the recording's notification", error)
                }
                return
            }
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, RecordingService::class.java).setAction(ACTION_SHOW),
                )
                running = true
            } catch (error: RuntimeException) {
                Log.w(TAG, "Could not show the recording outside the app", error)
            }
        }

        /**
         * Takes it away. Through the service rather than around it: one asked
         * to start must reach startForeground before it may stop.
         */
        fun hide(context: Context) {
            if (!running) return
            running = false
            try {
                context.startService(Intent(context, RecordingService::class.java).setAction(ACTION_HIDE))
            } catch (error: RuntimeException) {
                context.stopService(Intent(context, RecordingService::class.java))
            }
        }

        private fun notification(context: Context): Notification {
            ensureChannel(context)
            val state = shown
            val recording = !state.paused && !state.interrupted
            val title = when {
                state.interrupted -> R.string.recording_interrupted
                state.paused -> R.string.recording_paused
                else -> R.string.recording_title
            }
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_dictate)
                .setColor(ContextCompat.getColor(context, R.color.recording_clay))
                .setContentTitle(context.getString(title))
                .setContentIntent(openIntent(context))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            if (recording) {
                builder.setShowWhen(true).setUsesChronometer(true).setWhen(state.startedAt)
            } else {
                // A chronometer cannot stand still, so a paused one is text.
                builder.setShowWhen(false).setSubText(DateUtils.formatElapsedTime(state.elapsedMs / 1000))
            }
            if (recording) {
                builder.addAction(R.drawable.ic_pause, context.getString(R.string.recording_pause), commandIntent(context, ACTION_PAUSE))
            } else {
                builder.addAction(R.drawable.ic_play, context.getString(R.string.recording_resume), commandIntent(context, ACTION_RESUME))
            }
            builder.addAction(R.drawable.ic_stop, context.getString(R.string.recording_stop), commandIntent(context, ACTION_STOP))
            if (state.phrase != null) showPhrase(context, builder, state.phrase, state.heard)
            if (state.live && Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                builder.addExtras(Bundle().apply { putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true) })
            }
            return builder.build()
        }

        /**
         * The live translation, as words nobody else should read off a
         * locked phone: private, with a public version that says only that
         * it is recording. Whether a locked phone shows the words is then
         * the person's own lock-screen setting, where today's public
         * notification would show them to anyone. Updated on every phrase,
         * never with a sound or a buzz: the builder already alerts only once.
         */
        private fun showPhrase(context: Context, builder: NotificationCompat.Builder, phrase: String, heard: String?) {
            val hidden = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_dictate)
                .setColor(ContextCompat.getColor(context, R.color.recording_clay))
                .setContentTitle(context.getString(R.string.recording_title))
                .setContentText(context.getString(R.string.recording_live_hidden))
                .setOngoing(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build()
            builder
                .setContentText(phrase)
                .setStyle(NotificationCompat.BigTextStyle().bigText(if (heard == null) phrase else "$phrase\n$heard"))
                .setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(hidden)
        }

        /**
         * Silent, but not a silent notification: those are left off the lock
         * screen, and that is where somebody looks for a recording.
         */
        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.recording_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.recording_channel_description)
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }

        private fun openIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                Intent(context, MainActivity::class.java)
                    .setAction(ACTION_OPEN)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun commandIntent(context: Context, action: String): PendingIntent =
            PendingIntent.getService(
                context,
                action.hashCode(),
                Intent(context, RecordingService::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }
}
