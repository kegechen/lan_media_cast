package com.iflytek.lanmediacast.receiver.playback

import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Test

class LocalMediaClientPolicyTest {
    @Test
    fun `streaming requests use inactivity timeouts without a total deadline`() {
        val client = configureLocalMediaTimeouts(OkHttpClient.Builder()).build()

        assertEquals(5_000, client.connectTimeoutMillis)
        assertEquals(15_000, client.readTimeoutMillis)
        assertEquals(0, client.callTimeoutMillis)
    }
}
