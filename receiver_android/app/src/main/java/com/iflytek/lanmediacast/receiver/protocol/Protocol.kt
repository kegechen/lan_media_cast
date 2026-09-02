package com.iflytek.lanmediacast.receiver.protocol

import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

object ProtocolLimits {
    const val VERSION = 1
    const val MAX_UDP_BYTES = 1_400
    const val MAX_TEXT_FRAME_BYTES = 64 * 1_024
    const val MAX_BINARY_FRAME_BYTES = 128 * 1_024
    const val MAX_NAME_BYTES = 256
    const val MAX_PLAYLIST_ITEMS = 500
    const val MAX_PHOTO_ITEMS = 9
    const val MAX_RECEIVER_LOG_CHUNK_BYTES = 16 * 1_024
}

@Serializable
data class DiscoveryQuery(
    val v: Int,
    val type: String,
    val requestId: String,
    val senderId: String,
    val senderName: String,
)

@Serializable
data class DiscoveryResponse(
    val v: Int = ProtocolLimits.VERSION,
    val type: String = "discover.response",
    val requestId: String,
    val deviceId: String,
    val deviceName: String,
    val wssPort: Int,
    val busy: Boolean,
    val pairingRequired: Boolean,
    val protocolMin: Int = ProtocolLimits.VERSION,
    val protocolMax: Int = ProtocolLimits.VERSION,
    val capabilities: List<String>,
)

data class Envelope(
    val version: Int,
    val type: String,
    val id: String?,
    val replyTo: String?,
    val sessionId: String?,
    val commandSeq: Long?,
    val timestamp: Long,
    val payload: JsonObject,
)

class ProtocolException(val code: String, message: String) : IllegalArgumentException(message)

object ProtocolCodec {
    val json = Json {
        ignoreUnknownKeys = false
        explicitNulls = true
        encodeDefaults = true
    }

    private val sideEffectTypes = setOf(
        "media.endpoint.announce",
        "playlist.replace",
        "mode.set",
        "player.play",
        "player.pause",
        "player.stop",
        "player.seek",
        "player.select",
        "player.next",
        "player.previous",
        "player.repeat",
        "player.volume",
        "player.mute",
        "photo.batch.start",
        "photo.batch.update",
        "photo.batch.cancel",
        "photo.item.meta",
        "photo.batch.resume.query",
        "photo.operation",
        "diagnostics.logs.get",
    )

    fun decodeDiscoveryQuery(bytes: ByteArray): DiscoveryQuery {
        if (bytes.size > ProtocolLimits.MAX_UDP_BYTES) {
            throw ProtocolException("message_too_large", "UDP datagram exceeds protocol limit")
        }
        val query = try {
            json.decodeFromString<DiscoveryQuery>(bytes.toString(Charsets.UTF_8))
        } catch (error: Exception) {
            throw ProtocolException("invalid_message", "Malformed discovery query: ${error.message}")
        }
        requireProtocol(query.v, query.type, "discover.query")
        requireUuid(query.requestId, "requestId")
        requireUuid(query.senderId, "senderId")
        requireUtf8Length(query.senderName, "senderName")
        return query
    }

    fun decodeEnvelope(text: String): Envelope {
        if (text.toByteArray(Charsets.UTF_8).size > ProtocolLimits.MAX_TEXT_FRAME_BYTES) {
            throw ProtocolException("message_too_large", "WSS text frame exceeds protocol limit")
        }
        val root = try {
            json.parseToJsonElement(text).jsonObject
        } catch (error: Exception) {
            // kotlinx appends a "JSON input: <raw frame window>" tail. That window is peer
            // controlled and can carry a `trustedToken`, so keep only the diagnostic prefix
            // rather than relying on downstream redaction to claw it back.
            val detail = (error.message ?: error.javaClass.simpleName)
                .substringBefore("\nJSON input:")
                .take(200)
            throw ProtocolException("invalid_message", "Malformed JSON envelope: $detail")
        }
        val version = root.int("v")
        val type = root.string("type")
        requireProtocol(version, type, type)
        if (!TYPE_PATTERN.matches(type)) {
            throw ProtocolException("invalid_message", "Invalid message type: ${describeType(type)}")
        }
        val id = root.optionalString("id")
        val replyTo = root.optionalString("replyTo")
        val sessionId = root.optionalString("sessionId")
        val commandSeq = root["commandSeq"]?.jsonPrimitive?.longOrNull
        val timestamp = root["ts"]?.jsonPrimitive?.longOrNull
            ?: throw ProtocolException("invalid_message", "Missing or invalid ts")
        val payload = root["payload"] as? JsonObject
            ?: throw ProtocolException("invalid_message", "payload must be an object")

        id?.let { requireUuid(it, "id") }
        replyTo?.let { requireUuid(it, "replyTo") }
        sessionId?.let { requireUuid(it, "sessionId") }
        if (commandSeq != null && commandSeq < 1) {
            throw ProtocolException("invalid_message", "commandSeq must be positive")
        }
        if (type in sideEffectTypes) {
            if (id == null || sessionId == null || commandSeq == null) {
                throw ProtocolException("invalid_message", "Command requires id, sessionId and commandSeq")
            }
        }
        if (type == "session.hello" && (sessionId != null || commandSeq != null)) {
            throw ProtocolException("invalid_message", "session.hello must be outside a session")
        }
        if (type == "protocol.error") validateProtocolError(replyTo, commandSeq, payload)

        return Envelope(version, type, id, replyTo, sessionId, commandSeq, timestamp, payload)
    }

    private fun validateProtocolError(replyTo: String?, commandSeq: Long?, payload: JsonObject) {
        if (replyTo != null || commandSeq != null) {
            throw ProtocolException("invalid_message", "protocol.error cannot reply to a command")
        }
        if (payload["ok"]?.jsonPrimitive?.booleanOrNull != false) {
            throw ProtocolException("invalid_message", "protocol.error payload.ok must be false")
        }
        val reason = payload["reason"]?.jsonPrimitive?.contentOrNull
        if (reason !in setOf("malformed_binary_header", "unknown_transfer", "internal_error")) {
            throw ProtocolException("invalid_message", "Unknown protocol.error reason")
        }
        if (!payload.containsKey("transferId")) {
            throw ProtocolException("invalid_message", "protocol.error requires transferId")
        }
    }

    private fun requireProtocol(version: Int, actualType: String, expectedType: String) {
        if (version != ProtocolLimits.VERSION) {
            throw ProtocolException("unsupported_version", "Unsupported protocol version")
        }
        if (actualType != expectedType) {
            throw ProtocolException("invalid_message", "Unexpected message type")
        }
    }

    private fun requireUuid(value: String, field: String) {
        try {
            UUID.fromString(value)
        } catch (_: IllegalArgumentException) {
            throw ProtocolException("invalid_message", "$field must be an RFC 4122 UUID")
        }
    }

    private fun requireUtf8Length(value: String, field: String) {
        val size = value.toByteArray(Charsets.UTF_8).size
        if (size !in 1..ProtocolLimits.MAX_NAME_BYTES) {
            throw ProtocolException("invalid_message", "$field has an invalid UTF-8 length")
        }
    }

    fun requireMessageType(type: String) {
        if (!TYPE_PATTERN.matches(type)) {
            throw ProtocolException("invalid_message", "Invalid message type: ${describeType(type)}")
        }
    }

    private fun describeType(type: String): String {
        val shortened = if (type.length <= 64) type else type.take(64) + "..."
        return JsonPrimitive(shortened).toString()
    }

    private fun JsonObject.int(name: String): Int = this[name]?.jsonPrimitive?.intOrNull
        ?: throw ProtocolException("invalid_message", "Missing or invalid $name")

    private fun JsonObject.string(name: String): String = this[name]?.jsonPrimitive?.contentOrNull
        ?: throw ProtocolException("invalid_message", "Missing or invalid $name")

    private fun JsonObject.optionalString(name: String): String? {
        val value: JsonElement = this[name] ?: return null
        return value.jsonPrimitive.contentOrNull
    }

    private val TYPE_PATTERN = Regex("^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*$")
}
