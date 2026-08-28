package com.iflytek.lanmediacast.receiver.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingChallengeTest {
    @Test
    fun `incorrect code can be retried with the same challenge`() {
        val challenge = challenge()

        assertEquals(PairingDecision.INCORRECT_CODE, challenge.verify(ID, "000000", 500L))
        assertEquals(PairingDecision.ACCEPTED, challenge.verify(ID, "123456", 600L))
    }

    @Test
    fun `mismatched challenge id does not consume the active challenge`() {
        val challenge = challenge()

        assertEquals(PairingDecision.INVALID_CHALLENGE, challenge.verify("other", "123456", 500L))
        assertEquals(PairingDecision.ACCEPTED, challenge.verify(ID, "123456", 600L))
    }

    @Test
    fun `accepted challenge cannot be replayed`() {
        val challenge = challenge()

        assertEquals(PairingDecision.ACCEPTED, challenge.verify(ID, "123456", 500L))
        assertEquals(PairingDecision.ALREADY_CONSUMED, challenge.verify(ID, "123456", 600L))
    }

    @Test
    fun `expired challenge is consumed and can be retired by a timer`() {
        val submitted = challenge()
        assertEquals(PairingDecision.EXPIRED, submitted.verify(ID, "123456", 1_001L))
        assertEquals(PairingDecision.ALREADY_CONSUMED, submitted.verify(ID, "123456", 1_002L))

        val timed = challenge()
        assertFalse(timed.expireIfNeeded(1_000L))
        assertTrue(timed.expireIfNeeded(1_001L))
        assertFalse(timed.expireIfNeeded(1_002L))
    }

    private fun challenge() = PairingChallenge(ID, "123456", 1_000L)

    private companion object {
        const val ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }
}
