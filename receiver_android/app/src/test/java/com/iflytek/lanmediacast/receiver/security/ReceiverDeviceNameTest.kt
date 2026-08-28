package com.iflytek.lanmediacast.receiver.security

import org.junit.Assert.assertEquals
import org.junit.Test

class ReceiverDeviceNameTest {
    @Test
    fun `system device name wins over hardware identifiers`() {
        assertEquals("Xiaomi 14", resolveDeviceName(" Xiaomi 14 ", "Xiaomi", "23127PN0CC"))
    }

    @Test
    fun `manufacturer and model form a readable fallback`() {
        assertEquals("Xiaomi 23127PN0CC", resolveDeviceName(null, "Xiaomi", "23127PN0CC"))
        assertEquals("Xiaomi 14", resolveDeviceName("null", "Xiaomi", "Xiaomi 14"))
    }

    @Test
    fun `missing identifiers have a stable fallback`() {
        assertEquals("Android 设备", resolveDeviceName(" ", "", ""))
    }
}
