package com.iflytek.lanmediacast.receiver.protocol

import java.net.URI
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

data class RemoteMediaTrack(
    val source: JsonObject,
    val httpHeaders: Map<String, String>,
)

data class ValidatedRemoteMediaSource(
    val primaryTrack: RemoteMediaTrack,
    val audioTrack: RemoteMediaTrack?,
)

object RemoteMediaSourceValidator {
    fun validate(source: JsonObject): ValidatedRemoteMediaSource {
        require(source["kind"]?.let(::stringValue) == "url") { "remote media source kind must be url" }
        val name = source["name"]?.let(::stringValue)
        require(name != null && name.isNotBlank() && name.toByteArray(Charsets.UTF_8).size <= 256) {
            "remote media source name is invalid"
        }
        val primaryTrack = validateTrack(source, allowRtsp = true)
        val audioTrack = source["audioTrack"]?.let { element ->
            validateTrack(element.jsonObject, allowRtsp = false, allowAdaptiveManifest = false)
        }
        if (audioTrack != null) {
            require(source["formatHint"] == null) {
                "split remote media tracks must be progressive files"
            }
        }
        return ValidatedRemoteMediaSource(primaryTrack, audioTrack)
    }

    fun validateTrack(
        source: JsonObject,
        allowRtsp: Boolean,
        allowAdaptiveManifest: Boolean = true,
    ): RemoteMediaTrack {
        val rawUrl = source["url"]?.let(::stringValue)
        require(rawUrl != null && rawUrl.toByteArray(Charsets.UTF_8).size <= 4_096) {
            "Remote media URL is invalid"
        }
        val uri = runCatching { URI(rawUrl) }.getOrNull()
        val allowedSchemes = if (allowRtsp) setOf("http", "https", "rtsp") else setOf("http", "https")
        require(uri != null && uri.scheme?.lowercase() in allowedSchemes && !uri.host.isNullOrEmpty()) {
            "Remote media URL is invalid"
        }
        val formatHint = source["formatHint"]?.let(::stringValue)?.lowercase()
        require(formatHint == null || formatHint in setOf("hls", "dash", "rtsp")) {
            "Remote media format is invalid"
        }
        require(allowAdaptiveManifest || formatHint == null) {
            "split remote media tracks must be progressive files"
        }
        require((formatHint == "rtsp") == (uri.scheme.equals("rtsp", ignoreCase = true))) {
            "RTSP format and URL must match"
        }
        val cacheKey = source["cacheKey"]?.let(::stringValue)
        require(cacheKey == null || (cacheKey.isNotEmpty() && cacheKey.toByteArray(Charsets.UTF_8).size <= 256)) {
            "Remote media cache key is invalid"
        }
        val headers = RemoteHttpHeaders.fromSource(source)
        require(!uri.scheme.equals("rtsp", ignoreCase = true) || headers.isEmpty()) {
            "RTSP source cannot contain HTTP headers"
        }
        return RemoteMediaTrack(source, headers)
    }

    private fun stringValue(element: kotlinx.serialization.json.JsonElement): String? {
        val primitive = element as? JsonPrimitive
        return if (primitive?.isString == true) primitive.contentOrNull else null
    }
}
