package com.iflytek.lanmediacast.receiver.network

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import com.iflytek.lanmediacast.receiver.protocol.DiscoveryResponse
import com.iflytek.lanmediacast.receiver.protocol.ProtocolCodec
import com.iflytek.lanmediacast.receiver.protocol.ProtocolException
import com.iflytek.lanmediacast.receiver.security.ReceiverIdentity
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.io.IOException
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class DiscoveryResponder(
    context: Context,
    private val identity: ReceiverIdentity,
    private val controlPort: () -> Int,
    private val isBusy: () -> Boolean,
) : AutoCloseable {
    private val running = AtomicBoolean(false)
    private val wifiLock = (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
        ?.createMulticastLock("lan-media-cast-discovery")
        ?.apply { setReferenceCounted(false) }
    private val datagramLoop = DiscoveryDatagramLoop(
        port = DISCOVERY_PORT,
        onPacket = ::handle,
        onRecoverableError = { error -> Log.w(TAG, "Discovery packet failed", error) },
        onFatalError = { error ->
            if (running.get()) Log.e(TAG, "Discovery socket failed", error)
        },
    )

    fun start() {
        if (!running.compareAndSet(false, true)) return
        try {
            wifiLock?.acquire()
            datagramLoop.start()
        } catch (error: Exception) {
            running.set(false)
            if (wifiLock?.isHeld == true) wifiLock.release()
            throw error
        }
    }

    private fun handle(packet: DatagramPacket, datagramSocket: DatagramSocket) {
        try {
            val query = ProtocolCodec.decodeDiscoveryQuery(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
            val response = DiscoveryResponse(
                requestId = query.requestId,
                deviceId = identity.deviceId,
                deviceName = identity.deviceName,
                wssPort = controlPort(),
                busy = isBusy(),
                pairingRequired = true,
                capabilities = listOf("media", "photo", "hls", "dash", "rtsp", "cache"),
            )
            val bytes = ProtocolCodec.json.encodeToString(DiscoveryResponse.serializer(), response)
                .toByteArray(Charsets.UTF_8)
            datagramSocket.send(DatagramPacket(bytes, bytes.size, packet.address, packet.port))
        } catch (_: ProtocolException) {
            // Discovery is unauthenticated; malformed packets are dropped without reflection traffic.
        }
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        datagramLoop.close()
        if (wifiLock?.isHeld == true) wifiLock.release()
    }

    private companion object {
        const val TAG = "DiscoveryResponder"
        const val DISCOVERY_PORT = 39_880
    }
}

internal class DiscoveryDatagramLoop(
    private val port: Int,
    private val onPacket: (DatagramPacket, DatagramSocket) -> Unit,
    private val onRecoverableError: (Throwable) -> Unit = {},
    private val onFatalError: (Throwable) -> Unit = {},
) : AutoCloseable {
    private val running = AtomicBoolean(false)

    @Volatile
    private var socket: DatagramSocket? = null

    @Volatile
    private var worker: Thread? = null

    val localPort: Int
        get() = socket?.localPort ?: 0

    @Synchronized
    fun start() {
        if (!running.compareAndSet(false, true)) return
        val boundSocket = DatagramSocket(null)
        try {
            boundSocket.reuseAddress = true
            boundSocket.broadcast = true
            boundSocket.bind(InetSocketAddress(port))
            socket = boundSocket
            worker = thread(name = "cast-discovery", isDaemon = true) {
                receiveLoop(boundSocket)
            }
        } catch (error: Exception) {
            running.set(false)
            boundSocket.close()
            socket = null
            throw error
        }
    }

    private fun receiveLoop(boundSocket: DatagramSocket) {
        val buffer = ByteArray(1_401)
        try {
            while (running.get()) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    boundSocket.receive(packet)
                } catch (error: SocketException) {
                    if (running.get()) onFatalError(error)
                    break
                } catch (error: IOException) {
                    if (running.get()) onRecoverableError(error)
                    continue
                } catch (error: RuntimeException) {
                    if (running.get()) onRecoverableError(error)
                    continue
                }
                try {
                    onPacket(packet, boundSocket)
                } catch (error: IOException) {
                    if (running.get()) onRecoverableError(error)
                } catch (error: RuntimeException) {
                    if (running.get()) onRecoverableError(error)
                }
            }
        } finally {
            running.set(false)
            boundSocket.close()
            if (socket === boundSocket) socket = null
        }
    }

    @Synchronized
    override fun close() {
        running.set(false)
        val activeWorker = worker
        socket?.close()
        activeWorker?.interrupt()
        if (activeWorker != null && activeWorker !== Thread.currentThread()) {
            activeWorker.join(1_000)
        }
        worker = null
        socket = null
    }
}
