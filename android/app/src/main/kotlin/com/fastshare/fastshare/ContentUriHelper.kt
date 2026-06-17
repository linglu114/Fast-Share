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
import androidx.documentfile.provider.DocumentFile

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

    /// Public variant for share-intent processing — takes ContentResolver directly
    /// since the caller (MainActivity) already has `contentResolver` in scope.
    fun buildShareFileInfo(resolver: android.content.ContentResolver, uri: Uri): Map<String, Any?> {
        var name = "unknown"
        var size = 0L
        try {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) name = cursor.getString(nameIdx) ?: name
                    if (sizeIdx >= 0) size = cursor.getLong(sizeIdx)
                }
            }
        } catch (_: Exception) {}
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size,
            "realPath" to null,
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
            val pfd = context.contentResolver.openFileDescriptor(uri, "r") ?: run {
                android.util.Log.w("FastShare", "openContentFd: openFileDescriptor returned null for $uriStr")
                return -1
            }
            openPfds[uriStr] = pfd
            openChannels[uriStr] = FileInputStream(pfd.fileDescriptor).channel
            android.util.Log.d("FastShare", "openContentFd: opened fd=${pfd.fd} for $uriStr")
            pfd.fd
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "openContentFd FAILED for $uriStr: ${e.javaClass.simpleName}: ${e.message}", e)
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

    /// Opens ACTION_OPEN_DOCUMENT_TREE result, takes persistable permission,
    /// and recursively collects every file under the tree as content-file maps.
    /// Returns empty list when user cancels or an error occurs.
    fun parseFolderPickResult(context: Context, data: Intent?): List<Map<String, Any?>> {
        if (data == null) {
            android.util.Log.d("FastShare", "parseFolderPickResult: data is null (user cancelled)")
            return emptyList()
        }

        val treeUri = data.data
        if (treeUri == null) {
            android.util.Log.w("FastShare", "parseFolderPickResult: data.data is null")
            return emptyList()
        }

        android.util.Log.d("FastShare", "parseFolderPickResult: treeUri=$treeUri")
        // Persist permission across reboots
        try {
            context.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {}

        val rootDoc = DocumentFile.fromTreeUri(context, treeUri) ?: run {
            android.util.Log.w("ContentUriHelper", "fromTreeUri returned null for $treeUri")
            return emptyList()
        }

        // Include the selected folder name as the base prefix so the receiver
        // creates files under SavePath/SelectedFolder/... instead of flat in SavePath.
        val baseName = rootDoc.name ?: ""
        val prefix = if (baseName.isNotEmpty()) "$baseName/" else ""
        return traverseTree(context, rootDoc, prefix)
    }

    /// Recursively traverse [parent], collecting file entries into a flat list.
    /// Each entry follows the same shape as pickFiles results:
    ///   { uri, name (relative path within tree), size, realPath (null for SAF) }
    private fun traverseTree(
        context: Context,
        parent: DocumentFile,
        prefix: String
    ): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val children = try {
            parent.listFiles()
        } catch (e: Exception) {
            android.util.Log.w("ContentUriHelper", "listFiles failed for ${parent.uri}: $e")
            return result
        }

        if (children == null) return result

        for (child in children) {
            try {
                if (child.isDirectory) {
                    val subPrefix = if (prefix.isEmpty()) "${child.name}/" else "$prefix${child.name}/"
                    result.addAll(traverseTree(context, child, subPrefix))
                } else if (child.isFile) {
                    var size = 0L
                    try { size = child.length() } catch (_: Exception) {}

                    result.add(mapOf(
                        "uri" to child.uri.toString(),
                        "name" to "$prefix${child.name}",
                        "size" to size,
                        "realPath" to null,
                    ))
                }
                // skip other types (virtual containers, etc.)
            } catch (e: Exception) {
                android.util.Log.w("ContentUriHelper", "Skipping child in traverseTree: $e")
            }
        }

        return result
    }
}
