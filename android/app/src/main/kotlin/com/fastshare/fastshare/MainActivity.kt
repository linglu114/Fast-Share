package com.fastshare.fastshare

import android.app.Activity
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var pickFilesResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
    }

    companion object {
        private const val PICK_FILES_REQUEST = 1001
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

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
