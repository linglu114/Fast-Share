package com.fastshare.fastshare

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File

object ContentUriHelper {

    fun parsePickResult(context: Context, data: Intent): List<Map<String, Any?>> {
        val files = mutableListOf<Map<String, Any?>>()

        fun addUri(uri: Uri) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}
            files.add(buildFileInfo(context, uri))
        }

        // Single file selection
        data.data?.let { addUri(it) }

        // Multiple file selection
        data.clipData?.let { clipData ->
            for (i in 0 until clipData.itemCount) {
                addUri(clipData.getItemAt(i).uri)
            }
        }

        return files
    }

    private fun buildFileInfo(context: Context, uri: Uri): Map<String, Any?> {
        var name = "unknown"
        var size = 0L
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) {
                        name = cursor.getString(nameIdx) ?: name
                    }
                    if (sizeIdx >= 0) {
                        size = cursor.getLong(sizeIdx)
                    }
                }
            }
        } catch (_: Exception) {}

        val realPath = tryResolveRealPath(context, uri)

        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size,
            "realPath" to realPath,
        )
    }

    /// Best-effort: resolve a content:// URI to a real filesystem path.
    /// Returns null on modern Android (scoped storage) but many OEMs still
    /// expose the _data column. When available, the engine reads the file
    /// directly without any content-URI overhead.
    private fun tryResolveRealPath(context: Context, uri: Uri): String? {
        try {
            context.contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex("_data")
                    if (idx >= 0) {
                        val path = cursor.getString(idx)
                        if (path != null && File(path).canRead()) return path
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }

    fun readChunk(context: Context, uriStr: String, offset: Int, length: Int): ByteArray? {
        return try {
            val uri = Uri.parse(uriStr)
            context.contentResolver.openInputStream(uri)?.use { input ->
                var skipped = 0L
                while (skipped < offset) {
                    val s = input.skip(offset - skipped)
                    if (s <= 0) break
                    skipped += s
                }
                val buffer = ByteArray(length)
                var totalRead = 0
                while (totalRead < length) {
                    val n = input.read(buffer, totalRead, length - totalRead)
                    if (n < 0) break
                    totalRead += n
                }
                if (totalRead > 0) buffer.copyOf(totalRead) else ByteArray(0)
            }
        } catch (_: Exception) {
            null
        }
    }
}
