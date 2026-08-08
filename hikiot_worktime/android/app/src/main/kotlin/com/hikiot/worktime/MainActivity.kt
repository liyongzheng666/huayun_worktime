package com.hikiot.worktime

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val deviceInfoChannel = "com.hikiot.worktime/device_info"
    private val appUpdateChannel = "com.hikiot.worktime/app_update"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceInfoChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrand" -> result.success(Build.BRAND)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appUpdateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppVersion" -> result.success(getAppVersion())
                    "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                    "openInstallPermissionSettings" -> openInstallPermissionSettings(result)
                    "verifyAndInstallApk" -> {
                        val path = call.argument<String>("path")
                        val expectedSha256 = call.argument<String>("expectedSha256")
                        verifyAndInstallApk(path, expectedSha256, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 返回 Android 实际安装版本，避免 Dart 与原生版本号口径分裂。 */
    private fun getAppVersion(): Map<String, Any> {
        val packageInfo = packageManager.getPackageInfo(packageName, 0)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (packageInfo.versionName ?: "0.0.0"),
            "versionCode" to versionCode,
        )
    }

    private fun canRequestPackageInstalls(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    /** 打开当前应用的“安装未知应用”授权页。 */
    private fun openInstallPermissionSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null)
            return
        }

        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            result.error("SETTINGS_UNAVAILABLE", "系统没有可用的未知来源安装设置页", null)
        }
    }

    /**
     * 原生侧重新计算 SHA-256 后才把 APK 交给系统安装器。
     * 只允许读取应用 cache/updates，拒绝由 Flutter 传入任意文件路径。
     */
    private fun verifyAndInstallApk(
        path: String?,
        expectedSha256: String?,
        result: MethodChannel.Result,
    ) {
        if (path.isNullOrBlank() || expectedSha256.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "APK 路径或 SHA-256 缺失", null)
            return
        }

        try {
            val apkFile = File(path).canonicalFile
            val updatesDirectory = File(cacheDir, "updates").canonicalFile
            val allowedPrefix = updatesDirectory.path + File.separator
            if (!apkFile.path.startsWith(allowedPrefix) || !apkFile.isFile) {
                result.error("INVALID_APK_PATH", "APK 不在允许的更新缓存目录中", null)
                return
            }

            val actualSha256 = sha256(apkFile)
            if (!actualSha256.equals(expectedSha256, ignoreCase = true)) {
                result.error("CHECKSUM_MISMATCH", "APK 的 SHA-256 校验失败", null)
                return
            }

            if (!canRequestPackageInstalls()) {
                result.success("permissionRequired")
                return
            }

            val apkUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apkFile,
            )
            val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                data = apkUri
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            result.success("launched")
        } catch (error: Exception) {
            result.error("INSTALL_FAILED", error.message ?: "无法打开系统安装器", null)
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    /**
     * 创建最高优先级通知渠道
     * 确保所有国产系统（小米、华为、OPPO、vivo等）默认开启所有通知功能
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "punch_reminder_high"
            val channelName = "打卡提醒"
            val channelDesc = "上下班打卡提醒通知（高优先级）"
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            
            // 删除所有旧渠道，确保重新创建
            notificationManager.deleteNotificationChannel("punch_reminder")
            notificationManager.deleteNotificationChannel("punch_reminder_high")
            
            // 创建新的最高优先级渠道
            // 使用 IMPORTANCE_HIGH (4) - 这是通知能使用的最高级别
            // IMPORTANCE_MAX (5) 仅用于系统级别，普通App无法使用
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = channelDesc
                
                // 启用振动 - 必须在创建时设置，之后无法修改
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 200, 500)
                
                // 启用声音 - 使用系统默认通知铃声
                val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                val audioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE) // 使用铃声级别
                    .build()
                setSound(soundUri, audioAttributes)
                
                // 启用LED灯
                enableLights(true)
                lightColor = 0xFF2196F3.toInt()
                
                // 显示角标
                setShowBadge(true)
                
                // 锁屏完整显示
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                
                // 允许绕过勿扰模式（Android 8.0+）
                setBypassDnd(false) // 不绕过勿扰，避免被系统拒绝
            }
            
            notificationManager.createNotificationChannel(channel)
            
            // 输出日志确认渠道创建
            val createdChannel = notificationManager.getNotificationChannel(channelId)
            if (createdChannel != null) {
                println("通知渠道创建成功: importance=${createdChannel.importance}, sound=${createdChannel.sound}, vibration=${createdChannel.shouldVibrate()}")
            }
        }
    }
}
