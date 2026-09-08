package com.kapybara.kapynotes

import android.content.ContentProvider
import android.content.ContentValues
import android.content.ClipDescription
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/** Read-only access to the one cache file currently owned by the clipboard. */
class ClipboardImageProvider : ContentProvider() {
    companion object {
        private val safeName = Regex("[A-Za-z0-9._-]+")

        fun htmlFileFor(context: android.content.Context, uri: Uri): File? {
            val image = imageFileFor(context, uri) ?: return null
            return File(image.parentFile, "${image.nameWithoutExtension}.html")
        }

        private fun imageFileFor(context: android.content.Context, uri: Uri): File? {
            if (uri.pathSegments.size != 2 || uri.pathSegments[0] != "image") return null
            val name = uri.pathSegments[1]
            if (!name.matches(safeName)) return null
            val directory = File(context.cacheDir, "clipboard")
            val file = File(directory, name)
            return file.takeIf {
                it.parentFile?.canonicalFile == directory.canonicalFile
            }
        }
    }

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Clipboard images are read-only")
        val file = fileFor(uri)
        if (!file.isFile) throw FileNotFoundException("Clipboard image is gone")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? {
        val offered = listOfNotNull(
            getType(uri),
            "text/html".takeIf { htmlFile(uri)?.isFile == true },
        ).filter { ClipDescription.compareMimeTypes(it, mimeTypeFilter) }
        return offered.takeIf { it.isNotEmpty() }?.toTypedArray()
    }

    override fun openTypedAssetFile(
        uri: Uri,
        mimeTypeFilter: String,
        opts: Bundle?,
    ): AssetFileDescriptor {
        val file = when {
            ClipDescription.compareMimeTypes("text/html", mimeTypeFilter) -> htmlFile(uri)
            getType(uri)?.let { ClipDescription.compareMimeTypes(it, mimeTypeFilter) } == true ->
                fileFor(uri)
            else -> null
        }
        if (file?.isFile != true) throw FileNotFoundException("Clipboard type is gone")
        return AssetFileDescriptor(
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY),
            0,
            AssetFileDescriptor.UNKNOWN_LENGTH,
        )
    }

    override fun getType(uri: Uri): String? = when (fileFor(uri).extension.lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "bmp" -> "image/bmp"
        "tif", "tiff" -> "image/tiff"
        "heic" -> "image/heic"
        "heif" -> "image/heif"
        "png" -> "image/png"
        else -> null
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val wanted = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val columns = wanted.filter {
            it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE
        }
        return MatrixCursor(columns.toTypedArray(), 1).apply {
            addRow(columns.map {
                if (it == OpenableColumns.DISPLAY_NAME) "Kapy Notes image.${file.extension}"
                else file.length()
            })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private fun fileFor(uri: Uri): File {
        val context = context ?: throw FileNotFoundException("Provider is detached")
        return imageFileFor(context, uri)
            ?: throw FileNotFoundException("Unknown clipboard URI")
    }

    private fun htmlFile(uri: Uri): File? {
        val context = context ?: return null
        return htmlFileFor(context, uri)
    }
}
