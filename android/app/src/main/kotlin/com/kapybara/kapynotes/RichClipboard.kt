package com.kapybara.kapynotes

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.text.Charsets.UTF_8

/** Publishes one selection as text, HTML, and a native image at the same time. */
object RichClipboard {
    private const val channelName = "kapynotes/rich_clipboard"

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            write(appContext, call.arguments as? Map<String, Any?> ?: emptyMap())
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("clipboard_write", error.message, null)
                        }
                    }

                    "readHtml" -> {
                        try {
                            result.success(readHtml(appContext))
                        } catch (error: Exception) {
                            result.error("clipboard_read", error.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun write(context: Context, arguments: Map<String, Any?>) {
        val text = arguments["text"] as? String ?: ""
        val html = arguments["html"] as? String ?: ""
        val bytes = arguments["image"] as? ByteArray
        val imageMime = (arguments["imageMime"] as? String)
            ?.takeIf { it.startsWith("image/") }

        var imageUri: Uri? = null
        var imageFile: File? = null
        var htmlFile: File? = null
        if (bytes != null && bytes.isNotEmpty() && imageMime != null) {
            val directory = File(context.cacheDir, "clipboard").apply { mkdirs() }
            val extension = extensionFor(imageMime)
            val name = "selection-${System.currentTimeMillis()}"
            imageFile = File(directory, "$name.$extension")
            htmlFile = File(directory, "$name.html")
            imageFile.writeBytes(bytes)
            htmlFile.writeText(html, UTF_8)
            imageUri = Uri.Builder()
                .scheme("content")
                .authority("${context.packageName}.clipboard")
                .appendPath("image")
                .appendPath(imageFile.name)
                .build()
        }

        try {
            val mimeTypes = buildList {
                add(ClipDescription.MIMETYPE_TEXT_PLAIN)
                add(ClipDescription.MIMETYPE_TEXT_HTML)
                if (imageMime != null && imageUri != null) add(imageMime)
            }
            // ClipData rejects HTML above 800 KB. The provider advertises the
            // same text/html stream for larger selections, so clients can
            // still negotiate it without sending megabytes through Binder.
            // A conservative UTF-16 length avoids allocating a second encoded
            // copy merely to count bytes; 200K code units remain below the cap
            // even when every character needs three UTF-8 bytes.
            val inlineHtml = html.takeIf {
                it.isNotEmpty() && it.length <= 200 * 1024
            }
            val item = ClipData.Item(text, inlineHtml, null, imageUri)
            val clip = ClipData(
                ClipDescription("Kapy Notes selection", mimeTypes.toTypedArray()),
                item,
            )
            val manager = context.getSystemService(ClipboardManager::class.java)
            manager.setPrimaryClip(clip)

            // The URI on the new clipboard now names [imageFile]. Older cache
            // entries are no longer observable and can be reclaimed at once.
            imageFile?.parentFile?.listFiles()?.forEach { candidate ->
                if (candidate != imageFile && candidate != htmlFile) candidate.delete()
            }
        } catch (error: Exception) {
            imageFile?.delete()
            htmlFile?.delete()
            throw error
        }
    }

    private fun readHtml(context: Context): String? {
        val manager = context.getSystemService(ClipboardManager::class.java)
        val clip = manager.primaryClip ?: return null
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            item.htmlText?.let { return it }
            item.uri?.let { uri ->
                ClipboardImageProvider.htmlFileFor(context, uri)
                    ?.takeIf(File::isFile)
                    ?.readText(UTF_8)
                    ?.let { return it }
            }
        }
        return null
    }

    private fun extensionFor(mime: String): String = when (mime.lowercase()) {
        "image/jpeg" -> "jpg"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        "image/bmp" -> "bmp"
        "image/tiff" -> "tiff"
        "image/heic" -> "heic"
        "image/heif" -> "heif"
        else -> "png"
    }
}
