package com.kapybara.kapynotes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Backs the `kapynotes/file_export` channel: "where do you want this?", asked
 * by Android rather than drawn by the app.
 *
 * `ACTION_CREATE_DOCUMENT` is the Storage Access Framework's own picker — the
 * one every other app uses to put a file into Downloads, Drive, or wherever
 * else a provider offers. It hands back a `content://` document rather than a
 * path, so the bytes are copied into the stream it opens; there is nothing to
 * write to with `File` and no storage permission involved.
 *
 * The Dart side builds the archive into a temporary file first and gives this
 * its path, because the picker is a question rather than a writer: it creates
 * an empty document and leaves the filling to whoever asked.
 */
object FileExport {
    private const val CHANNEL = "kapynotes/file_export"
    private const val REQUEST = 0x4B45 // "KE"

    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private var activityFor: (() -> Activity)? = null

    fun register(messenger: BinaryMessenger, activity: () -> Activity): MethodChannel {
        activityFor = activity
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> save(call, result)
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val name = call.argument<String>("suggestedName") ?: "export"
        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
        val file = path?.let { File(it) }
        if (file == null || !file.exists()) {
            result.error("missing", "That file is no longer there.", null)
            return
        }
        val activity = activityFor?.invoke()
        if (activity == null) {
            result.error("no-activity", "Nothing to open a picker from.", null)
            return
        }

        // Anything still waiting cannot be answered: the picker about to open
        // is the only one the user can see.
        finish(null)
        pending = result
        source = file

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (error: Exception) {
            pending = null
            source = null
            result.error("no-picker", "This device has no file picker.", null)
        }
    }

    /** True when this was ours to deal with, so the activity can stop looking. */
    fun handleResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val uri = data?.data
        val file = source
        source = null
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            finish(null)
            return true
        }
        // Off the main thread: this is the whole archive going through a
        // content provider, and a picture-heavy note list is not small.
        Thread {
            val name = copyInto(uri, file)
            Handler(Looper.getMainLooper()).post {
                if (name == null) {
                    finishWithError("Kapy Notes could not write to that place.")
                } else {
                    finish(name)
                }
            }
        }.start()
        return true
    }

    /** The document's display name once it holds the bytes, or null if it could not. */
    private fun copyInto(uri: Uri, file: File): String? {
        val activity = activityFor?.invoke() ?: return null
        val resolver = activity.contentResolver
        return try {
            resolver.openOutputStream(uri, "wt").use { output ->
                if (output == null) return null
                file.inputStream().use { input -> input.copyTo(output) }
            }
            displayName(uri) ?: file.name
        } catch (error: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? {
        val activity = activityFor?.invoke() ?: return null
        return try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
            }
        } catch (error: Exception) {
            null
        }
    }

    /** Answers the waiting call once, with the name it was saved as or null for a dismissal. */
    private fun finish(name: String?) {
        val result = pending ?: return
        pending = null
        result.success(name)
    }

    private fun finishWithError(message: String) {
        val result = pending ?: return
        pending = null
        result.error("write-failed", message, null)
    }
}
