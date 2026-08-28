package com.iflytek.lanmediacast.receiver.network

import java.net.InetSocketAddress
import javax.net.ssl.SSLContext
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.server.DefaultSSLWebSocketServerFactory
import org.java_websocket.server.WebSocketServer

abstract class SecureWebSocketServer(
    port: Int,
    sslContext: SSLContext,
) : WebSocketServer(InetSocketAddress(port), 1, listOf(Draft_6455())) {
    init {
        setWebSocketFactory(DefaultSSLWebSocketServerFactory(sslContext))
        isReuseAddr = true
        connectionLostTimeout = 0
    }
}
