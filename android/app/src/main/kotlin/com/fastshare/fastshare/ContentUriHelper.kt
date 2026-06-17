package com.fastshare.fastshare

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.database.Cursor
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

object ContentUriHelper {

    // 持久持有 ParcelFileDescriptor 防止 GC 关闭底层 fd
    private val openPfds = LinkedHashMap<String, ParcelFileDescriptor>()
    // 持久 FileChannel，支持 O(1) seek (lseek64)，消除 O(n²) skip 开销
    private val openChannels = LinkedHashMap<String, FileChannel>()
    // Android 15 上 openFileDescriptor 可能因 SecurityException 失败，
    // 使用持久 InputStream + 跟踪位置作为回退 (O(1) 相对 skip)
    private val openStreams = LinkedHashMap<String, java.io.InputStream>()
    private val streamPositions = LinkedHashMap<String, Long>()

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
    /// 返回 -1 表示打开失败（回退到 readChunk 路径）。
    fun openContentFd(context: Context, uriStr: String): Int {
        openPfds[uriStr]?.let { return it.fd }

        val uri = Uri.parse(uriStr)

        // Strategy 1: direct openFileDescriptor on the given URI
        val fd = tryOpenFileDescriptor(context, uri)
        if (fd >= 0) return fd

        // Strategy 2: if the URI is a document URI, extract the document ID
        // and try to find the real filesystem path to open via FileInputStream.
        // On Android 15, DownloadsProvider document URIs are not covered by
        // tree permission grants, but the files themselves are readable at
        // the filesystem level if we know their real path.
        val docId = extractDocumentId(uri)
        if (docId != null) {
            // Try to resolve _data column from the document URI
            val realPath = tryResolveRealPath(context, uri)
            if (realPath != null) {
                return tryOpenRealFile(uriStr, realPath)
            }
        }

        // Strategy 3: fallback to openInputStream
        if (openStream(context, uriStr)) return -1

        return -1
    }

    private fun tryOpenRealFile(uriStr: String, realPath: String): Int {
        return try {
            val file = File(realPath)
            if (!file.canRead()) return -1
            val fis = FileInputStream(file)
            openPfds[uriStr] = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            openChannels[uriStr] = fis.channel
            val pfd = openPfds[uriStr]!!
            android.util.Log.e("FastShare", "openContentFd OK (real file): fd=${pfd.fd} path=$realPath")
            pfd.fd
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "openRealFile FAILED: ${e.message}")
            -1
        }
    }

    /// Returns fd on success, -1 on any failure. Does NOT cache — caller caches.
    private fun tryOpenFileDescriptor(context: Context, uri: Uri): Int {
        return try {
            val pfd = context.contentResolver.openFileDescriptor(uri, "r")
            if (pfd == null) {
                android.util.Log.e("FastShare", "openFileDescriptor null for $uri")
                return -1
            }
            openPfds[uri.toString()] = pfd
            openChannels[uri.toString()] = FileInputStream(pfd.fileDescriptor).channel
            android.util.Log.e("FastShare", "openContentFd OK: fd=${pfd.fd} uri=$uri")
            pfd.fd
        } catch (e: SecurityException) {
            android.util.Log.e("FastShare", "openFileDescriptor SecurityException for $uri: ${e.message}")
            -1
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "openFileDescriptor FAILED for $uri: ${e.javaClass.simpleName}: ${e.message}")
            -1
        }
    }

    /// Extract the raw document ID from a content:// URI's last path segment.
    /// e.g. content://.../document/msf%3A1000010965 → "msf:1000010965"
    private fun extractDocumentId(uri: Uri): String? {
        val last = uri.lastPathSegment ?: return null
        return Uri.decode(last)
    }

    private fun openStream(context: Context, uriStr: String): Boolean {
        if (openStreams.containsKey(uriStr)) return true
        return try {
            val uri = Uri.parse(uriStr)
            val s = context.contentResolver.openInputStream(uri)
            if (s != null) {
                openStreams[uriStr] = s
                streamPositions[uriStr] = 0L
                true
            } else { false }
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "openStream FAILED for $uriStr: ${e.message}")
            false
        }
    }

    fun readChunk(context: Context, uriStr: String, offset: Int, length: Int): ByteArray? {
        val channel = openChannels[uriStr]
        if (channel != null) {
            return try {
                channel.position(offset.toLong())
                val buf = ByteBuffer.allocate(length)
                var total = 0
                while (total < length) { val n = channel.read(buf); if (n < 0) break; total += n }
                if (total > 0) { buf.flip(); ByteArray(total).also { buf.get(it) } } else ByteArray(0)
            } catch (_: Exception) { null }
        }
        val cachedStream = openStreams[uriStr]
        if (cachedStream != null) {
            return try {
                val curPos = streamPositions[uriStr] ?: 0L
                val target = offset.toLong()
                if (target > curPos) {
                    var skipped = 0L
                    val skipBuf = ByteArray(8192)
                    while (skipped < target - curPos) {
                        val n = cachedStream.read(skipBuf, 0, minOf(skipBuf.size.toLong(), target - curPos - skipped).toInt())
                        if (n < 0) break; skipped += n
                    }
                } else if (target < curPos) {
                    try { cachedStream.close() } catch (_: Exception) {}
                    openStreams.remove(uriStr); streamPositions.remove(uriStr)
                    return readChunk(context, uriStr, offset, length)
                }
                val buf = ByteArray(length); var total = 0
                while (total < length) { val n = cachedStream.read(buf, total, length - total); if (n < 0) break; total += n }
                streamPositions[uriStr] = target + total
                if (total > 0) { if (total == length) buf else buf.copyOf(total) } else ByteArray(0)
            } catch (e: Exception) { android.util.Log.e("FastShare", "stream readChunk FAILED: ${e.message}"); null }
        }
        if (openStream(context, uriStr)) return readChunk(context, uriStr, offset, length)
        return null
    }

    fun closeContentStream(uriStr: String) {
        openChannels.remove(uriStr)?.close()
        try { openPfds.remove(uriStr)?.close() } catch (_: Exception) {}
        try { openStreams.remove(uriStr)?.close() } catch (_: Exception) {}
        streamPositions.remove(uriStr)
    }

    fun closeAllContentStreams() {
        for ((_, ch) in openChannels) { try { ch.close() } catch (_: Exception) {} }
        openChannels.clear()
        for ((_, pfd) in openPfds) { try { pfd.close() } catch (_: Exception) {} }
        openPfds.clear()
        for ((_, s) in openStreams) { try { s.close() } catch (_: Exception) {} }
        openStreams.clear()
        streamPositions.clear()
    }

    // ═══════════════════════════════════════════════════════════
    // Folder picker — DocumentsContract-based tree traversal
    //
    // Uses DocumentsContract.buildChildDocumentsUriUsingTree() +
    // ContentResolver.query() instead of DocumentFile because
    // DocumentFile.isDirectory/isFile throws SecurityException on
    // Android 15 when the app lacks descendant-level permission
    // (which is always the case under scoped storage).
    //
    // Reading strategy:
    // On Android 15, the DownloadsProvider rejects openFileDescriptor
    // on document URIs built from the tree (both buildDocumentUri
    // and buildDocumentUriUsingTree variants). To work around this,
    // we resolve the real filesystem path for every file by
    // reconstructing it from the tree structure:
    //   /storage/emulated/0/Download/<folderName>/<relativePath>
    // When the real path is readable, the Flutter engine bypasses
    // SAF entirely and reads via dart:io File API.
    // ═══════════════════════════════════════════════════════════

    private val PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
    )

    /// Opens ACTION_OPEN_DOCUMENT_TREE result, takes persistable permission,
    /// and recursively collects every file under the tree as content-file maps.
    /// Returns empty list when user cancels or an error occurs.
    fun parseFolderPickResult(context: Context, data: Intent?): List<Map<String, Any?>> {
        if (data == null) {
            android.util.Log.e("FastShare", "parseFolderPickResult: data is null")
            return emptyList()
        }

        val treeUri = data.data
        if (treeUri == null) {
            android.util.Log.e("FastShare", "parseFolderPickResult: data.data is null")
            return emptyList()
        }

        android.util.Log.e("FastShare", "parseFolderPickResult: treeUri=$treeUri")

        // Persist permission across reboots
        try {
            context.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "takePersistableUriPermission FAILED: ${e.message}")
        }

        // Extract root document ID from tree URI
        val rootDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "getTreeDocumentId FAILED: ${e.message}")
            return emptyList()
        }

        android.util.Log.e("FastShare", "parseFolderPickResult: rootDocId=$rootDocId")

        // Get root document to extract folder name
        val rootDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId)
        var baseName = ""
        try {
            context.contentResolver.query(rootDocUri, PROJECTION, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    baseName = cursor.getString(1) ?: ""
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "root doc query FAILED: ${e.message}")
        }

        val prefix = if (baseName.isNotEmpty()) "$baseName/" else ""
        android.util.Log.e("FastShare", "parseFolderPickResult: baseName='$baseName' prefix='$prefix'")

        // Resolve the real filesystem root for the selected folder.
        // On Android the Downloads directory maps to the public Download folder.
        // Constructing the real path lets us bypass SAF entirely for reading —
        // on Android 15 the DownloadsProvider refuses openFileDescriptor on
        // document URIs, but direct filesystem access works when the path is known.
        val downloadsRoot = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS).absolutePath
        android.util.Log.e("FastShare", "parseFolderPickResult: downloadsRoot=$downloadsRoot")

        val files = traverseTree(context, treeUri, rootDocId, prefix, downloadsRoot)

        android.util.Log.e("FastShare", "parseFolderPickResult: found ${files.size} files total")
        return files
    }

    private fun traverseTree(
        context: Context,
        treeUri: Uri,
        parentDocId: String,
        prefix: String,
        downloadsRoot: String
    ): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        var cursor: Cursor? = null

        try {
            cursor = context.contentResolver.query(
                childrenUri, PROJECTION, null, null, null
            )
            if (cursor == null) {
                android.util.Log.e("FastShare", "traverseTree: query null for docId=$parentDocId")
                return result
            }

            while (cursor.moveToNext()) {
                try {
                    val docId = cursor.getString(0)
                    val name = cursor.getString(1)
                    val mime = cursor.getString(2)
                    val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)

                    if (docId == null || name == null) continue
                    val isDir = DocumentsContract.Document.MIME_TYPE_DIR == mime

                    if (isDir) {
                        result.addAll(traverseTree(
                            context, treeUri, docId, "$prefix$name/", downloadsRoot))
                    } else {
                        val authority = treeUri.authority ?: continue
                        val fileUri = DocumentsContract.buildDocumentUri(authority, docId)

                        // Resolve the real filesystem path:
                        // 1. Try _data column from the document URI (works for some files)
                        // 2. Construct from tree structure: <downloadsRoot>/<prefix><name>
                        //    e.g. /storage/emulated/0/Download/QQ/StarRail_4.3.0.apk
                        val relativePath = "$prefix$name"
                        val realPath = tryResolveRealPath(context, fileUri)
                            ?: "$downloadsRoot/$relativePath".let { candidate ->
                                if (File(candidate).canRead()) candidate else null
                            }

                        result.add(mapOf(
                            "uri" to fileUri.toString(),
                            "name" to relativePath,
                            "size" to size,
                            "realPath" to realPath,
                        ))
                    }
                } catch (e: Exception) {
                    android.util.Log.e("FastShare", "traverseTree skip: ${e.javaClass.simpleName}: ${e.message}")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("FastShare", "traverseTree query FAILED for $parentDocId: ${e.javaClass.simpleName}: ${e.message}", e)
        } finally {
            cursor?.close()
        }

        return result
    }
}
