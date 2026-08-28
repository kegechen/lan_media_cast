package com.iflytek.lanmediacast.receiver.protocol

import java.io.File
import java.util.UUID
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PhotoChunkCodecTest {
    private val fixture = ProtocolCodec.json.parseToJsonElement(
        File("../../protocol/fixtures/v1/valid/photo_chunk_frame.json").readText(Charsets.UTF_8),
    ).jsonObject
    private val boundaryFixture = ProtocolCodec.json.parseToJsonElement(
        File("../../protocol/fixtures/v1/valid/photo_chunk_boundaries.json").readText(Charsets.UTF_8),
    ).jsonObject

    @Test
    fun `encoding matches the shared fixed fixture`() {
        val frame = PhotoChunkFrame(
            transferId = UUID.fromString(fixture.getValue("transferId").jsonPrimitive.content),
            chunkIndex = fixture.getValue("chunkIndex").jsonPrimitive.int.toLong(),
            isLast = fixture.getValue("last").jsonPrimitive.boolean,
            payload = fixture.getValue("payloadHex").jsonPrimitive.content.hexBytes(),
        )

        assertEquals(fixture.getValue("frameHex").jsonPrimitive.content, PhotoChunkCodec.encode(frame).hex())
        val decoded = PhotoChunkCodec.decode(PhotoChunkCodec.encode(frame))
        assertEquals(frame.transferId, decoded.transferId)
        assertEquals(frame.chunkIndex, decoded.chunkIndex)
        assertEquals(frame.isLast, decoded.isLast)
        assertArrayEquals(frame.payload, decoded.payload)
    }

    @Test
    fun `decoder rejects malformed structure`() {
        val valid = fixture.getValue("frameHex").jsonPrimitive.content.hexBytes()
        val badMagic = valid.copyOf().also { it[0] = 0 }
        val badFlags = valid.copyOf().also { it[7] = 2 }
        listOf(valid.copyOf(31), badMagic, badFlags, valid.copyOf(valid.size - 1)).forEach { bytes ->
            assertThrows(IllegalArgumentException::class.java) { PhotoChunkCodec.decode(bytes) }
        }
    }

    @Test
    fun `boundary vectors decode consistently`() {
        boundaryFixture.getValue("cases").jsonArray.forEach { element ->
            val boundary = element.jsonObject
            val decoded = PhotoChunkCodec.decode(boundary.getValue("frameHex").jsonPrimitive.content.hexBytes())
            assertEquals(
                boundaryFixture.getValue("transferId").jsonPrimitive.content,
                decoded.transferId.toString(),
            )
            assertEquals(boundary.getValue("chunkIndex").jsonPrimitive.int.toLong(), decoded.chunkIndex)
            assertArrayEquals(byteArrayOf(0xaa.toByte()), decoded.payload)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PhotoChunkCodec.decode(boundaryFixture.getValue("malformedHeaderHex").jsonPrimitive.content.hexBytes())
        }
    }

    private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
