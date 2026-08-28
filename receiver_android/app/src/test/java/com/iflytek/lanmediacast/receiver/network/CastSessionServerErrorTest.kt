package com.iflytek.lanmediacast.receiver.network

import java.util.UUID
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CastSessionServerErrorTest {
    @Test
    fun `internal photo error payload retains transfer identity and is non-terminal`() {
        val transferId = UUID.randomUUID().toString()
        val payload = photoInternalErrorPayload(transferId)

        assertFalse(payload.getValue("ok").jsonPrimitive.boolean)
        assertEquals("internal_error", payload.getValue("code").jsonPrimitive.content)
        assertEquals("internal_error", payload.getValue("reason").jsonPrimitive.content)
        assertEquals(transferId, payload.getValue("transferId").jsonPrimitive.content)
    }

    @Test
    fun `successful media selection reveals player after photo mode`() {
        assertTrue(commandRevealsMedia("player.select", buildJsonObject { put("ok", true) }))
        assertFalse(commandRevealsMedia("player.select", buildJsonObject { put("ok", false) }))
        assertFalse(commandRevealsMedia("player.pause", buildJsonObject { put("ok", true) }))
    }
}
