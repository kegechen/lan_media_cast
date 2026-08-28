package com.iflytek.lanmediacast.receiver.playback

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CacheWritePolicyTest {
    @Test
    fun `disables after low capacity is stable and enables after recovery`() {
        val mib = 1_024L * 1_024L
        val policy = CacheWritePolicy(initialEnabled = true)

        assertTrue(policy.update(255L * mib, 0L))
        assertTrue(policy.update(255L * mib, 29_999L))
        assertFalse(policy.update(255L * mib, 30_000L))
        assertFalse(policy.update(320L * mib, 30_000L))
        assertFalse(policy.update(320L * mib, 89_999L))
        assertTrue(policy.update(320L * mib, 90_000L))
    }

    @Test
    fun `emergency exhaustion disables immediately`() {
        val policy = CacheWritePolicy(initialEnabled = true)
        assertFalse(policy.update(0L, 1L))
    }
}
