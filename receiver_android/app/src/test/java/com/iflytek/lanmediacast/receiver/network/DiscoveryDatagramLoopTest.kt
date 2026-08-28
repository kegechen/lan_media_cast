package com.iflytek.lanmediacast.receiver.network

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryDatagramLoopTest {
    @Test
    fun `immediate close releases the bound port`() {
        val loop = DiscoveryDatagramLoop(port = 0, onPacket = { _, _ -> })
        loop.start()
        val port = loop.localPort

        loop.close()

        DatagramSocket(null).use { replacement ->
            replacement.reuseAddress = true
            replacement.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), port))
            assertEquals(port, replacement.localPort)
        }
    }

    @Test
    fun `one packet failure does not stop later discovery packets`() {
        val calls = AtomicInteger()
        val secondPacket = CountDownLatch(1)
        val recoverableErrors = AtomicInteger()
        val loop = DiscoveryDatagramLoop(
            port = 0,
            onPacket = { _, _ ->
                if (calls.incrementAndGet() == 1) throw SocketException("simulated send failure")
                secondPacket.countDown()
            },
            onRecoverableError = { recoverableErrors.incrementAndGet() },
        )
        loop.start()
        try {
            DatagramSocket().use { sender ->
                repeat(2) {
                    val bytes = byteArrayOf(it.toByte())
                    sender.send(
                        DatagramPacket(
                            bytes,
                            bytes.size,
                            InetAddress.getLoopbackAddress(),
                            loop.localPort,
                        ),
                    )
                }
            }

            assertTrue(secondPacket.await(2, TimeUnit.SECONDS))
            assertEquals(1, recoverableErrors.get())
        } finally {
            loop.close()
        }
    }
}
