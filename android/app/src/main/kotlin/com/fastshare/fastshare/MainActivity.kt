package com.fastshare.fastshare

import android.app.Activity
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.os.PowerManager
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var pickFilesResult: MethodChannel.Result? = null
    private var pickFolderResult: MethodChannel.Result? = null
    private var pendingShareResult: MethodChannel.Result? = null
    private var pendingShareData: List<Map<String, Any?>>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Share receiver channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fastshare/share").setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShare" -> {
                    val data = pendingShareData
                    pendingShareData = null
                    if (data != null) {
                        result.success(data)
                    } else {
                        result.success(emptyList<Map<String, Any?>>())
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ... existing channels follow

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fastshare/wifi_lock").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(true)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fastshare/device_info").setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceModel" -> result.success(Build.MODEL)
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fastshare/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    val title = call.argument<String>("title") ?: "瞬息"
                    val body = call.argument<String>("body") ?: "Running in background"
                    val intent = ForegroundService.createIntent(this@MainActivity, title, body)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopForegroundService" -> {
                    val intent = ForegroundService.stopIntent(this@MainActivity)
                    startService(intent)
                    result.success(true)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "瞬息"
                    val body = call.argument<String>("body") ?: ""
                    val progress = call.argument<Int>("progress")
                    val progressMax = call.argument<Int>("progressMax")
                    val intent = ForegroundService.updateIntent(
                        this@MainActivity, title, body, progress, progressMax
                    )
                    startService(intent)
                    result.success(true)
                }
                "hasManageStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(
                            android.os.Environment.isExternalStorageManager()
                        )
                    } else {
                        result.success(true) // API < 30 无需此权限
                    }
                }
                "requestManageStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(
                                android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION
                            ).apply {
                                data = Uri.parse("package:${packageName}")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", "Cannot open settings: ${e.message}", null)
                        }
                    } else {
                        result.success(true) // API < 30 无需此权限
                    }
                }
                "openFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("NOT_FOUND", "File not found: $path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this@MainActivity,
                            "${packageName}.fileprovider",
                            file
                        )
                        val mimeType = if (file.isDirectory) {
                            "resource/folder"
                        } else {
                            val ext = file.extension.lowercase()
                            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
                        }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(intent, "打开文件"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", "Cannot open file: $path", e.message)
                    }
                }
                "getBatteryLevel" -> {
                    // 使用 ACTION_BATTERY_CHANGED 读取框架层电量（可被 dumpsys battery set 覆盖）
                    val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                    val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
                    result.success(if (level >= 0 && scale > 0) level * 100 / scale else null)
                }
                "getThermalState" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
                        val status = powerManager?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
                        val stateStr = when (status) {
                            PowerManager.THERMAL_STATUS_NONE -> "none"
                            PowerManager.THERMAL_STATUS_LIGHT -> "light"
                            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                            else -> "unknown"
                        }
                        result.success(stateStr)
                    } else {
                        val powerManager = getSystemService(POWER_SERVICE) as? PowerManager
                        result.success(if (powerManager?.isPowerSaveMode == true) "power_save" else "normal")
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fastshare/content_uri").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFiles" -> {
                    pickFilesResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    startActivityForResult(intent, PICK_FILES_REQUEST)
                }
                "pickFolder" -> {
                    pickFolderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                 Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    }
                    startActivityForResult(intent, PICK_FOLDER_REQUEST)
                }
                "openContentFd" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val fd = ContentUriHelper.openContentFd(applicationContext, uri)
                    result.success(fd)
                }
                "readChunk" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val offset = call.argument<Int>("offset") ?: 0
                    val length = call.argument<Int>("length") ?: 0
                    val data = ContentUriHelper.readChunk(applicationContext, uri, offset, length)
                    result.success(data)
                }
                "closeContentStream" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    ContentUriHelper.closeContentStream(uri)
                    result.success(true)
                }
                "closeAllContentStreams" -> {
                    ContentUriHelper.closeAllContentStreams()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_FILES_REQUEST) {
            val result = pickFilesResult ?: return
            pickFilesResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                result.success(ContentUriHelper.parsePickResult(applicationContext, data))
            } else {
                result.success(emptyList<Map<String, Any?>>())
            }
        }
        if (requestCode == PICK_FOLDER_REQUEST) {
            val result = pickFolderResult ?: return
            pickFolderResult = null
            if (resultCode == Activity.RESULT_OK) {
                result.success(ContentUriHelper.parseFolderPickResult(applicationContext, data))
            } else {
                // User cancelled — return null so Dart can distinguish cancel from error
                result.success(null)
            }
        }
    }

    companion object {
        private const val PICK_FILES_REQUEST = 1001
        private const val PICK_FOLDER_REQUEST = 1002
    }

    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager
            if (wifiManager != null) {
                multicastLock = wifiManager.createMulticastLock("FastShare")
                multicastLock?.setReferenceCounted(false)
            }
        }
        try {
            multicastLock?.acquire()
        } catch (_: Exception) {}

        // Also acquire a partial wake lock to keep CPU running for transfers
        if (wakeLock == null) {
            val powerManager = applicationContext.getSystemService(POWER_SERVICE) as? PowerManager
            if (powerManager != null) {
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "FastShare::Transfer"
                )
                wakeLock?.setReferenceCounted(false)
            }
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (_: Exception) {}
        try {
            wakeLock?.release()
        } catch (_: Exception) {}
    }

    // ── Share intent handling ──

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Process share intent that launched the activity (cold start)
        intent?.let { processShareIntent(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        processShareIntent(intent)
    }

    private fun processShareIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return

        val files = mutableListOf<Map<String, Any?>>()

        // Text sharing
        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (sharedText != null) {
            files.add(mapOf(
                "uri" to "data:text/plain,${java.net.URLEncoder.encode(sharedText, "UTF-8")}",
                "name" to "shared_text.txt",
                "size" to sharedText.toByteArray().size.toLong(),
                "realPath" to null,
            ))
        }

        // Single file
        fun collectUri(uri: Uri?) {
            if (uri == null) return
            try {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}
            files.add(ContentUriHelper.buildShareFileInfo(contentResolver, uri))
        }

        // SEND: single URI
        (intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri)?.let { collectUri(it) }

        // SEND_MULTIPLE: list of URIs
        intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)?.forEach { parcel ->
            (parcel as? Uri)?.let { collectUri(it) }
        }

        if (files.isEmpty()) return

        pendingShareData = files
        // If Flutter engine is already attached, notify immediately
        try {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, "fastshare/share").invokeMethod("onShareReceived", files)
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
