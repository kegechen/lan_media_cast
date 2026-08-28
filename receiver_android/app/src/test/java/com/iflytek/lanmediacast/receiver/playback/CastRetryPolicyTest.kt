package com.iflytek.lanmediacast.receiver.playback

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Test

class CastRetryPolicyTest {
    @Test
    fun `http 500 becomes a visible permanent error after three retries`() {
        assertEquals(1_000L, castHttpRetryDelay(500, 1))
        assertEquals(2_000L, castHttpRetryDelay(500, 2))
        assertEquals(4_000L, castHttpRetryDelay(500, 3))
        assertEquals(C.TIME_UNSET, castHttpRetryDelay(500, 4))
    }

    @Test
    fun `http 404 and unclassified 4xx use the same bounded retry budget`() {
        assertEquals(C.TIME_UNSET, castHttpRetryDelay(404, 4))
        assertEquals(C.TIME_UNSET, castHttpRetryDelay(418, 4))
    }

    @Test
    fun `http 503 remains transient and respects retry after`() {
        assertEquals(7_000L, castHttpRetryDelay(503, 99, retryAfterSeconds = 7))
        assertEquals(10_000L, castHttpRetryDelay(503, 99))
    }
}
