package com.iflytek.lanmediacast.receiver.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.iflytek.lanmediacast.receiver.MainActivity
import com.iflytek.lanmediacast.receiver.R
import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.network.CastSessionServer
import com.iflytek.lanmediacast.receiver.network.DiscoveryResponder
import com.iflytek.lanmediacast.receiver.photo.PhotoExplainCoordinator
import com.iflytek.lanmediacast.receiver.playback.PlaybackCoordinator
import com.iflytek.lanmediacast.receiver.security.ReceiverIdentity
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket

class CastServerService : Service() {
    private lateinit var playback: PlaybackCoordinator
    private lateinit var sessionServer: CastSessionServer
    private lateinit var discovery: DiscoveryResponder
    private lateinit var photos: PhotoExplainCoordinator

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        try {
            startCastRuntime()
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start cast runtime", error)
            ReceiverRuntime.update {
                it.copy(banner = "接收服务启动失败：${error.javaClass.simpleName}", bannerIsError = true)
            }
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (::discovery.isInitialized) discovery.close()
        if (::sessionServer.isInitialized) sessionServer.shutdown()
        if (::photos.isInitialized) photos.close()
        if (::playback.isInitialized) playback.close()
        super.onDestroy()
    }

    private fun startCastRuntime() {
        val identity = ReceiverIdentity(this)
        val controlPort = findControlPort()
        playback = PlaybackCoordinator(this) { payload ->
            if (::sessionServer.isInitialized) sessionServer.sendPlayerState(payload)
        }
        photos = PhotoExplainCoordinator(this) { type, payload ->
            if (::sessionServer.isInitialized) sessionServer.sendSessionEvent(type, payload)
        }
        sessionServer = CastSessionServer(controlPort, identity, playback, photos)
        sessionServer.start()
        discovery = DiscoveryResponder(this, identity, { controlPort }, { sessionServer.isBusy })
        discovery.start()
        ReceiverRuntime.update {
            it.copy(
                deviceName = identity.deviceName,
                address = findLanAddress() ?: "未连接局域网",
                controlPort = controlPort,
                banner = null,
                bannerIsError = false,
            )
        }
    }

    private fun findControlPort(): Int {
        for (port in 39_881..39_890) {
            try {
                ServerSocket(port).use { return port }
            } catch (_: Exception) {
                // Try the next reserved control port.
            }
        }
        throw IllegalStateException("No control port is available")
    }

    private fun findLanAddress(): String? {
        val interfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        return interfaces.asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList().asSequence() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { it.isSiteLocalAddress }
            ?.hostAddress
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.service_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun createNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_upload_done)
        .setContentTitle(getString(R.string.service_notification_title))
        .setContentText(getString(R.string.service_notification_text))
        .setOngoing(true)
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        .build()

    private companion object {
        const val TAG = "CastServerService"
        const val CHANNEL_ID = "cast_server"
        const val NOTIFICATION_ID = 39880
    }
}
