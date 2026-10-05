package app.clipbridge.clipbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder

class BridgeService : Service() {
    private var lock: WifiManager.MulticastLock? = null
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        lock = wifi?.createMulticastLock("clipbridge")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "ClipBridge 正在局域网待命"
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foreground = true
        return START_STICKY
    }

    override fun onDestroy() {
        lock?.let { if (it.isHeld) it.release() }
        if (foreground) stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "局域网连接",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "保持 ClipBridge 在局域网中可被发现"
        manager.createNotificationChannel(channel)
        val alerts = NotificationChannel(
            ALERT_CHANNEL_ID,
            "传输通知",
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        manager.createNotificationChannel(alerts)
    }

    private fun buildNotification(text: String): Notification {
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ClipBridge")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentIntent(launch)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "clipbridge_presence"
        const val ALERT_CHANNEL_ID = "clipbridge_alerts"
        const val NOTIFICATION_ID = 47821
        const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            val intent = Intent(context, BridgeService::class.java).putExtra(EXTRA_TEXT, text)
            context.startForegroundService(intent)
        }

        fun update(context: Context, text: String) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("ClipBridge")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setOngoing(true)
                .build()
            manager.notify(NOTIFICATION_ID, notification)
        }
    }
}
