package com.fastshare.fastshare

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

object ContentUriHelper {

    // 持久持有 ParcelFileDescriptor 防止 GC 关闭底层 fd
    private val openPfds = LinkedHashMap<String, ParcelFileDescriptor>()
    // 持久 FileChannel，支持 O(1) seek (lseek64)，消除 O(n²) skip 开销
    private val openChannels = LinkedHashMap<String, FileChannel>()

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

    /// 打开 content URI 并返回文件描述符编号，用于 Engine Isolate 直读。
    /// PFD 引用保存在 openPfds 中防止 GC 关闭底层 fd。
    /// 返回 -1 表示打开失败。
    fun openContentFd(context: Context, uriStr: String): Int {
        // 已打开的 URI 直接返回现有 fd
        openPfds[uriStr]?.let { return it.fd }

        return try {
            val uri = Uri.parse(uriStr)
            val pfd = context.contentResolver.openFileDescriptor(uri, "r") ?: return -1
            openPfds[uriStr] = pfd
            // 同时打开 FileChannel 作为备用回退
            openChannels[uriStr] = FileInputStream(pfd.fileDescriptor).channel
            pfd.fd
        } catch (_: Exception) {
            -1
        }
    }

    /// Chunk read with O(1) seek via FileChannel.position() (lseek64).
    /// Keeps ParcelFileDescriptor + FileChannel open across calls to eliminate
    /// the O(n²) skip overhead of per-chunk open→skip→read→close.
    fun readChunk(context: Context, uriStr: String, offset: Int, length: Int): ByteArray? {
        return try {
            val channel = openChannels.getOrPut(uriStr) {
                val uri = Uri.parse(uriStr)
                val pfd = context.contentResolver.openFileDescriptor(uri, "r")
                    ?: return null
                // 必须保持 PFD 引用防止 GC finalize() 关闭底层 fd
                openPfds[uriStr] = pfd
                FileInputStream(pfd.fileDescriptor).channel
            }
            channel.position(offset.toLong())
            val buf = ByteBuffer.allocate(length)
            var total = 0
            while (total < length) {
                val n = channel.read(buf)
                if (n < 0) break
                total += n
            }
            if (total > 0) {
                buf.flip()
                val result = ByteArray(total)
                buf.get(result)
                result
            } else {
                ByteArray(0)
            }
        } catch (_: Exception) {
            null
        }
    }

    /// 关闭指定 URI 的持久 channel 和 PFD
    fun closeContentStream(uriStr: String) {
        openChannels.remove(uriStr)?.close()
        try { openPfds.remove(uriStr)?.close() } catch (_: Exception) {}
    }

    /// 关闭所有持久 channel 和 PFD
    fun closeAllContentStreams() {
        for ((_, ch) in openChannels) { try { ch.close() } catch (_: Exception) {} }
        openChannels.clear()
        for ((_, pfd) in openPfds) { try { pfd.close() } catch (_: Exception) {} }
        openPfds.clear()
    }
}
