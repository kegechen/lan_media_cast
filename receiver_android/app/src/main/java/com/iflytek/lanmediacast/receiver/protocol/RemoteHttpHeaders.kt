package com.iflytek.lanmediacast.receiver.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

object RemoteHttpHeaders {
    const val MAX_COUNT = 5
    const val MAX_VALUE_BYTES = 2_048
    const val MAX_TOTAL_BYTES = 4_096

    private val allowedNames = mapOf(
        "user-agent" to "User-Agent",
        "referer" to "Referer",
        "origin" to "Origin",
        "accept" to "Accept",
        "accept-language" to "Accept-Language",
    )

    fun fromSource(source: JsonObject): Map<String, String> {
        val rawHeaders = source["httpHeaders"] ?: return emptyMap()
        val headers = rawHeaders as? JsonObject
            ?: throw IllegalArgumentException("httpHeaders must be an object")
        require(headers.size <= MAX_COUNT) { "too many remote HTTP headers" }

        val normalized = linkedMapOf<String, String>()
        var totalBytes = 0
        headers.forEach { (rawName, element) ->
            val name = allowedNames[rawName.lowercase()]
                ?: throw IllegalArgumentException("remote HTTP header is not allowed: $rawName")
            require(!normalized.containsKey(name)) { "duplicate remote HTTP header: $name" }
            val primitive = element as? JsonPrimitive
            require(primitive != null && primitive.isString) { "HTTP header values must be strings" }
            val value = primitive.content
            require(
                value.isNotEmpty() &&
                    value.trim() == value &&
                    value.all { character -> character.code in 0x20..0x7e },
            ) {
                "invalid remote HTTP header value: $name"
            }
            val valueBytes = value.toByteArray(Charsets.UTF_8).size
            require(valueBytes <= MAX_VALUE_BYTES) { "remote HTTP header value is too large: $name" }
            totalBytes += name.toByteArray(Charsets.UTF_8).size + valueBytes
            require(totalBytes <= MAX_TOTAL_BYTES) { "remote HTTP headers are too large" }
            normalized[name] = value
        }
        return normalized
    }
}
