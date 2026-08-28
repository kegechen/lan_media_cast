package com.iflytek.lanmediacast.receiver.network

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.iflytek.lanmediacast.receiver.security.ReceiverIdentity
import java.net.URI
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import org.java_websocket.WebSocket
import org.java_websocket.client.WebSocketClient
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.handshake.ServerHandshake
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureWebSocketServerTest {
    @Test(timeout = 20_000)
    fun androidKeystoreCompletesWssHandshake() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val started = CountDownLatch(1)
        val opened = CountDownLatch(1)
        val serverError = AtomicReference<Exception?>()
        val server = object : SecureWebSocketServer(0, ReceiverIdentity(context).createServerSslContext()) {
            override fun onStart() = started.countDown()

            override fun onOpen(conn: WebSocket, handshake: ClientHandshake) = opened.countDown()

            override fun onMessage(conn: WebSocket, message: String) = Unit

            override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) = Unit

            override fun onError(conn: WebSocket?, ex: Exception) {
                serverError.compareAndSet(null, ex)
            }
        }
        val clientError = AtomicReference<Exception?>()
        var client: WebSocketClient? = null
        try {
            server.start()
            assertTrue("WSS server did not start", started.await(5, TimeUnit.SECONDS))
            client = object : WebSocketClient(URI("wss://127.0.0.1:${server.port}/v1/control")) {
                override fun onOpen(handshake: ServerHandshake) = Unit

                override fun onMessage(message: String) = Unit

                override fun onClose(code: Int, reason: String, remote: Boolean) = Unit

                override fun onError(ex: Exception) {
                    clientError.compareAndSet(null, ex)
                }
            }.apply {
                setSocketFactory(trustAllSslContext().socketFactory)
            }
            assertTrue(
                "WSS client did not connect: ${clientError.get()?.message}",
                client.connectBlocking(5, TimeUnit.SECONDS),
            )
            assertTrue("WSS server did not accept the client", opened.await(5, TimeUnit.SECONDS))
            assertNull("WSS server reported an error", serverError.get())
            assertNull("WSS client reported an error", clientError.get())
        } finally {
            client?.closeBlocking()
            server.stop(1_000)
        }
    }

    private fun trustAllSslContext(): SSLContext {
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit

            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(trustManager), SecureRandom())
        }
    }
}
