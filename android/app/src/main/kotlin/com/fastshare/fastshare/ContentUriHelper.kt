package com.fastshare.fastshare

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.FileDescriptor

object ContentUriHelper {

    private val openFds = mutableMapOf<Int, ParcelFileDescriptor>()

    /// Reflect FileDescriptor.fd (private int field) to get the raw fd number.
    /// This works on all API levels and keeps ParcelFileDescriptor alive for cleanup.
    private fun getFdNumber(fdObj: FileDescriptor): Int {
        val field = FileDescriptor::class.java.getDeclaredField("fd")
        field.isAccessible = true
        return field.getInt(fdObj)
    }

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

        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size
        )
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

    /// Open a content URI and return its raw file descriptor number.
    /// Call [closeFd] to release the ParcelFileDescriptor and close the fd.
    fun openFd(context: Context, uriStr: String): Int {
        val uri = Uri.parse(uriStr)
        val pfd = context.contentResolver.openFileDescriptor(uri, "r")
            ?: throw IllegalArgumentException("Cannot open file descriptor for $uriStr")
        val fd = getFdNumber(pfd.fileDescriptor)
        openFds[fd] = pfd
        return fd
    }

    /// Close a file descriptor previously opened with [openFd].
    fun closeFd(fd: Int) {
        openFds.remove(fd)?.close()
    }

    /// Close all open file descriptors.
    fun closeAllFds() {
        for (pfd in openFds.values) {
            try { pfd.close() } catch (_: Exception) {}
        }
        openFds.clear()
    }
}
