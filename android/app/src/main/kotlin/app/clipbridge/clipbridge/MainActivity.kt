package app.clipbridge.clipbridge

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Parcelable
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "app.clipbridge/platform"
    private var channel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private var clipSequence = 1
    private val io = Executors.newSingleThreadExecutor()
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = messenger
        messenger.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    requestNotifications()
                    val text = call.argument<String>("text") ?: "ClipBridge 正在局域网待命"
                    BridgeService.start(this, text)
                    result.success(null)
                }
                "updateService" -> {
                    val text = call.argument<String>("text") ?: "ClipBridge 正在局域网待命"
                    BridgeService.update(this, text)
                    result.success(null)
                }
                "stopService" -> {
                    stopService(Intent(this, BridgeService::class.java))
                    result.success(null)
                }
                "getClipboardText" -> result.success(readClipboardText())
                "setClipboardText" -> {
                    val text = call.argument<String>("text") ?: ""
                    clipboard().setPrimaryClip(ClipData.newPlainText("ClipBridge", text))
                    clipSequence += 1
                    result.success(null)
                }
                "getClipboardPng" -> result.success(readClipboardImage())
                "setClipboardPng" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("clipboard", "缺少图片数据", null)
                    } else {
                        publishBytes(bytes, "clipbridge.png", "image/png", gallery = true)?.let { uri ->
                            clipboard().setPrimaryClip(ClipData.newUri(contentResolver, "ClipBridge", uri))
                            clipSequence += 1
                        }
                        result.success(null)
                    }
                }
                "getClipboardSequence" -> result.success(clipSequence)
                "pasteCtrlV" -> result.success(mapOf("ok" to false, "reason" to "unsupported"))
                "notify" -> {
                    val title = call.argument<String>("title") ?: "ClipBridge"
                    val body = call.argument<String>("body") ?: ""
                    showAlert(title, body)
                    result.success(null)
                }
                "publishFile" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "file"
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    val gallery = call.argument<Boolean>("gallery") ?: false
                    if (path == null) {
                        result.error("storage", "缺少路径", null)
                    } else {
                        val uri = publishFile(File(path), name, mime, gallery)
                        result.success(uri?.toString())
                    }
                }
                "revealPath" -> {
                    val path = call.argument<String>("path") ?: ""
                    reveal(path)
                    result.success(null)
                }
                "takePendingShare" -> {
                    val share = pendingShare
                    pendingShare = null
                    result.success(share)
                }
                "trayUpdate", "showWindow", "hideWindow", "quit" -> result.success(null)
                else -> result.notImplemented()
            }
        }
        listenClipboard()
        captureShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShare(intent)
    }

    override fun onDestroy() {
        clipListener?.let { clipboard().removePrimaryClipChangedListener(it) }
        io.shutdownNow()
        super.onDestroy()
    }

    private fun clipboard(): ClipboardManager {
        return getSystemService(ClipboardManager::class.java)
    }

    private fun listenClipboard() {
        val listener = ClipboardManager.OnPrimaryClipChangedListener { clipSequence += 1 }
        clipListener = listener
        clipboard().addPrimaryClipChangedListener(listener)
    }

    private fun readClipboardText(): String? {
        val clip = clipboard().primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val text = clip.getItemAt(0).coerceToText(this)?.toString()
        return if (text.isNullOrBlank()) null else text
    }

    private fun readClipboardImage(): ByteArray? {
        val clip = clipboard().primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val uri = clip.getItemAt(0).uri ?: return null
        val mime = contentResolver.getType(uri) ?: return null
        if (!mime.startsWith("image/")) return null
        return contentResolver.openInputStream(uri)?.use { it.readBytes() }
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 47821)
    }

    private fun showAlert(title: String, body: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                BridgeService.ALERT_CHANNEL_ID,
                "传输通知",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            manager.createNotificationChannel(channel)
        }
        val notification = android.app.Notification.Builder(this, BridgeService.ALERT_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setAutoCancel(true)
            .build()
        manager.notify((System.currentTimeMillis() % 100000).toInt(), notification)
    }

    private fun captureShare(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        io.execute {
            val item = extractShare(intent)
            if (item != null) {
                pendingShare = item
                runOnUiThread { channel?.invokeMethod("onShare", item) }
            }
        }
    }

    private fun extractShare(intent: Intent): Map<String, Any?>? {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val uri = when (intent.action) {
            Intent.ACTION_SEND -> intent.parcelable<Uri>(Intent.EXTRA_STREAM)
            Intent.ACTION_SEND_MULTIPLE -> intent.parcelableList<Uri>(Intent.EXTRA_STREAM)?.firstOrNull()
            else -> null
        }
        if (uri == null) {
            if (text.isNullOrBlank()) return null
            return mapOf("text" to text, "name" to null, "path" to null, "mime" to "text/plain")
        }
        val mime = contentResolver.getType(uri) ?: intent.type ?: "application/octet-stream"
        val name = queryName(uri) ?: "shared"
        val length = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
        if (length > 200L * 1024L * 1024L) {
            return mapOf(
                "text" to "分享内容超过 200MB，未复制",
                "name" to name,
                "path" to null,
                "mime" to mime,
            )
        }
        val dir = File(cacheDir, "shares").apply { mkdirs() }
        val dest = File(dir, "${UUID.randomUUID()}_$name")
        contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        return mapOf(
            "text" to text,
            "name" to name,
            "path" to dest.absolutePath,
            "mime" to mime,
        )
    }

    private inline fun <reified T : Parcelable> Intent.parcelable(key: String): T? {
        return if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(key, T::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(key) as? T
        }
    }

    private inline fun <reified T : Parcelable> Intent.parcelableList(key: String): ArrayList<T>? {
        return if (Build.VERSION.SDK_INT >= 33) {
            getParcelableArrayListExtra(key, T::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableArrayListExtra(key)
        }
    }

    private fun queryName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return uri.lastPathSegment
    }

    private fun publishFile(file: File, name: String, mime: String, gallery: Boolean): Uri? {
        if (!file.exists()) return null
        if (Build.VERSION.SDK_INT < 29 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                47822,
            )
            return null
        }
        return if (Build.VERSION.SDK_INT >= 29) {
            val collection = if (gallery) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val values = android.content.ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    if (gallery) "Pictures/ClipBridge" else "Download/ClipBridge",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values) ?: return null
            contentResolver.openOutputStream(uri)?.use { output ->
                file.inputStream().use { input -> input.copyTo(output) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            uri
        } else {
            val root = Environment.getExternalStoragePublicDirectory(
                if (gallery) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_DOWNLOADS,
            )
            val folder = File(root, "ClipBridge").apply { mkdirs() }
            val dest = File(folder, name)
            file.copyTo(dest, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(dest.absolutePath), arrayOf(mime), null)
            Uri.fromFile(dest)
        }
    }

    private fun publishBytes(bytes: ByteArray, name: String, mime: String, gallery: Boolean): Uri? {
        val temp = File(cacheDir, name)
        temp.writeBytes(bytes)
        return publishFile(temp, name, mime, gallery)
    }

    private fun reveal(path: String) {
        if (path.isEmpty()) return
        val uri = if (path.startsWith("content://")) Uri.parse(path) else Uri.fromFile(File(path))
        val mime = contentResolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                MimeTypeMap.getFileExtensionFromUrl(path),
            )
            ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(view)
        } catch (_: Exception) {
            showAlert("ClipBridge", path)
        }
    }
}
