package com.iflytek.lanmediacast.receiver.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {
    @Test
    fun `formats the full six digit range with leading zeroes`() {
        assertEquals("000000", PairingCode.format(0))
        assertEquals("000042", PairingCode.format(42))
        assertEquals("999999", PairingCode.format(999_999))
    }

    @Test
    fun `rejects values outside the six digit range`() {
        assertThrows(IllegalArgumentException::class.java) { PairingCode.format(-1) }
        assertThrows(IllegalArgumentException::class.java) { PairingCode.format(1_000_000) }
    }

    @Test
    fun `accepts only six ASCII digits`() {
        assertTrue(PairingCode.isValid("012345"))
        assertFalse(PairingCode.isValid("12345"))
        assertFalse(PairingCode.isValid("12345a"))
        assertFalse(PairingCode.isValid(null))
    }
}
