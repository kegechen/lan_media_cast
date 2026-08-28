package com.iflytek.lanmediacast.receiver.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingRateLimiterTest {
    @Test
    fun `locks one source after five failures for thirty seconds`() {
        val limiter = PairingRateLimiter()
        repeat(5) { limiter.recordFailure("192.0.2.1", it.toLong()) }

        assertFalse(limiter.isAllowed("192.0.2.1", 5L))
        assertTrue(limiter.isAllowed("192.0.2.2", 5L))
        assertTrue(limiter.isAllowed("192.0.2.1", 30_005L))
    }

    @Test
    fun `global window cannot be bypassed by changing source`() {
        val limiter = PairingRateLimiter()
        repeat(20) { limiter.recordFailure("192.0.2.$it", it.toLong()) }

        assertFalse(limiter.isAllowed("198.51.100.1", 20L))
        assertTrue(limiter.isAllowed("198.51.100.1", 300_020L))
    }
}
