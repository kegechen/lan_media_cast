package com.iflytek.lanmediacast.receiver.protocol

import java.io.File
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ProtocolFixtureTest {
    private val fixtures = File("../../protocol/fixtures/v1")

    @Test
    fun `valid discovery fixtures decode`() {
        val query = ProtocolCodec.decodeDiscoveryQuery(read("valid/discover_query.json").toByteArray())
        assertEquals("Teacher-PC", query.senderName)
    }

    @Test
    fun `valid envelope fixtures decode`() {
        assertEquals("player.play", ProtocolCodec.decodeEnvelope(read("valid/command_envelope.json")).type)
        assertEquals("protocol.error", ProtocolCodec.decodeEnvelope(read("valid/protocol_error.json")).type)
        assertEquals(
            "internal_error",
            ProtocolCodec.decodeEnvelope(read("valid/protocol_internal_error.json"))
                .payload["reason"]?.jsonPrimitive?.content,
        )
        assertEquals("response", ProtocolCodec.decodeEnvelope(read("valid/response_envelope.json")).type)
        val ready = ProtocolCodec.decodeEnvelope(read("valid/session_ready.json"))
        assertEquals("Projector-01", ready.payload["deviceName"]?.jsonPrimitive?.content)
        assertEquals("12", ready.payload["playlistRevision"]?.jsonPrimitive?.content)
        assertEquals(
            "pairing_expired",
            ProtocolCodec.decodeEnvelope(read("valid/pairing_expired_response.json"))
                .payload["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content,
        )
        assertEquals("photo.batch.ready", ProtocolCodec.decodeEnvelope(read("valid/photo_batch_ready.json")).type)
        assertEquals("photo.item.ready", ProtocolCodec.decodeEnvelope(read("valid/photo_item_ready.json")).type)
        validatePhotoResume(ProtocolCodec.decodeEnvelope(read("valid/photo_batch_resume_state.json")).payload)
        assertEquals(
            "unknown_transfer",
            ProtocolCodec.decodeEnvelope(read("valid/photo_protocol_unknown_transfer.json"))
                .payload["reason"]?.jsonPrimitive?.content,
        )
        assertEquals(
            "null",
            ProtocolCodec.decodeEnvelope(read("valid/photo_protocol_malformed_header.json"))
                .payload["transferId"]?.jsonPrimitive?.content,
        )
    }

    @Test
    fun `invalid fixtures are rejected`() {
        assertThrows(ProtocolException::class.java) {
            ProtocolCodec.decodeDiscoveryQuery(read("invalid/discover_wrong_version.json").toByteArray())
        }
        listOf("command_missing_sequence.json", "invalid_message_type.json", "protocol_error_with_reply.json")
            .forEach { name ->
            assertThrows(ProtocolException::class.java) {
                ProtocolCodec.decodeEnvelope(read("invalid/$name"))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            validatePhotoResume(
                ProtocolCodec.decodeEnvelope(read("invalid/photo_resume_missing_nullable.json")).payload,
            )
        }
    }

    @Test
    fun `remote HTTP header fixtures enforce the shared allowlist`() {
        val valid = ProtocolCodec.json.parseToJsonElement(read("valid/remote_http_headers.json")).jsonObject
        assertEquals(
            listOf("User-Agent", "Referer", "Origin", "Accept", "Accept-Language"),
            RemoteHttpHeaders.fromSource(
                kotlinx.serialization.json.buildJsonObject { put("httpHeaders", valid) },
            ).keys.toList(),
        )

        val invalid = ProtocolCodec.json.parseToJsonElement(read("invalid/remote_http_headers.json")).jsonObject
        invalid.getValue("cases").jsonArray.forEach { headers ->
            assertThrows(IllegalArgumentException::class.java) {
                RemoteHttpHeaders.fromSource(
                    kotlinx.serialization.json.buildJsonObject { put("httpHeaders", headers) },
                )
            }
        }
    }

    @Test
    fun `split remote media source fixtures are synchronized`() {
        val valid = ProtocolCodec.json.parseToJsonElement(
            read("valid/split_remote_media_source.json"),
        ).jsonObject
        val normalized = RemoteMediaSourceValidator.validate(valid)
        assertEquals("web:example:primary", normalized.primaryTrack.source["cacheKey"]?.jsonPrimitive?.content)
        assertEquals("web:example:audio", normalized.audioTrack?.source?.get("cacheKey")?.jsonPrimitive?.content)

        val invalid = ProtocolCodec.json.parseToJsonElement(
            read("invalid/split_remote_media_source.json"),
        ).jsonObject
        invalid.getValue("cases").jsonArray.forEach { source ->
            assertThrows(IllegalArgumentException::class.java) {
                RemoteMediaSourceValidator.validate(source.jsonObject)
            }
        }
    }

    private fun validatePhotoResume(payload: kotlinx.serialization.json.JsonObject) {
        val expected = setOf("awaitingMeta", "ready", "partial", "complete", "removed")
        val seen = payload.getValue("items").jsonArray.map { element ->
            val item = element.jsonObject
            require(item.containsKey("transferId") && item.containsKey("nextChunkIndex")) {
                "nullable fields must be present"
            }
            item.getValue("status").jsonPrimitive.content.also { require(it in expected) }
        }.toSet()
        require(seen == expected) { "status fixture coverage incomplete" }
    }

    private fun read(relativePath: String): String {
        val file = File(fixtures, relativePath)
        check(file.isFile) { "Missing protocol fixture: ${file.absolutePath}" }
        return file.readText(Charsets.UTF_8)
    }
}
