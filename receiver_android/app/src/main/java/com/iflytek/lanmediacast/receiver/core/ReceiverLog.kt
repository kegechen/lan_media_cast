package com.iflytek.lanmediacast.receiver.core

import android.util.Log
import androidx.annotation.VisibleForTesting
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import kotlin.math.min
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Keeps a bounded copy of receiver diagnostics for retrieval by the paired sender. */
object ReceiverLog {
    private const val MAX_BYTES = 256 * 1024
    private const val MAX_ENTRY_BYTES = 8 * 1024
    private const val MAX_CHUNK_BYTES = 16 * 1024

    private val bearerPattern = Regex("""Bearer\s+[^\s,;]+""", RegexOption.IGNORE_CASE)
    private val cookiePattern = Regex("""Cookie\s*[:=]\s*[^\r\n]+""", RegexOption.IGNORE_CASE)
    private val urlPattern = Regex("""(https?|rtsp)://([^/\s?#]+)\S*""", RegexOption.IGNORE_CASE)

    /**
     * Credential-bearing fields quoted out of a raw frame. Decode failures embed the offending
     * input (see `ProtocolCodec.decodeEnvelope`), so a malformed `session.hello` would otherwise
     * park a peer's `trustedToken` in a buffer that any later-paired sender can retrieve.
     */
    private val sensitiveFieldPattern = Regex(
        // Matches the quoted JSON form only; a looser pattern would swallow the `Bearer` keyword
        // out of an `Authorization: Bearer <token>` header and leave the token itself exposed
        // (that shape is handled by [bearerPattern]).
        //
        // Both quotes are optional and the key is matched by SUFFIX, because decoder errors
        // minify the offending frame to a window around the failure offset and routinely clip
        // the front of the key -- `...ustedToken":"<secret>` has to redact just as reliably as
        // a pristine `"trustedToken":"<secret>"`.
        """"?[A-Za-z_]*(token|authorization|cookie|privatekey|certificatepem|password|secret)"?\s*:\s*"[^"]*"?""",
        RegexOption.IGNORE_CASE,
    )

    private val privateKeyPattern = Regex("""-----BEGIN [A-Z ]*PRIVATE KEY-----""")

    /** Pre-session lines retained before the rest go to logcat only. */
    private const val MAX_UNTRUSTED_ENTRIES = 20

    private val lock = Any()
    private val entries = ArrayDeque<String>()
    private var totalBytes = 0
    private var untrustedEntries = 0

    /**
     * Byte image of the buffer as it looked when the current retrieval started.
     *
     * Retrieval spans several requests, and the buffer keeps moving while it runs -- handling a
     * chunk request itself appends an entry, which evicts older ones once the ring is full. Reading
     * every chunk from one frozen image keeps a single fetch internally consistent, so offsets stay
     * meaningful from the first chunk to the last.
     */
    private var snapshot: ByteArray? = null

    fun d(tag: String, message: String) = record(Log.DEBUG, "D", tag, message, null)

    fun i(tag: String, message: String) = record(Log.INFO, "I", tag, message, null)

    fun w(tag: String, message: String, error: Throwable? = null) =
        record(Log.WARN, "W", tag, message, error)

    fun e(tag: String, message: String, error: Throwable? = null) =
        record(Log.ERROR, "E", tag, message, error)

    /**
     * Logs a line attributable to a peer that has not authenticated, under a bounded budget.
     *
     * Every pre-session path has to come through here. The retained ring is what the operator
     * later pulls over `diagnostics.logs.get`, so any unauthenticated LAN host that can drive a
     * log write -- malformed WSS handshakes, undeliverable discovery replies -- can otherwise
     * evict every real diagnostic just by repeating itself. Never pass a [Throwable]: stack
     * traces are 1-3 KiB each, which is most of the budget in one line.
     *
     * The budget is deliberately NOT reset per connection or per packet; the attacker chooses
     * how often those happen. Only [clearUntrustedBudget], on a genuine session, resets it.
     */
    fun untrusted(tag: String, message: String) {
        val retain = synchronized(lock) {
            // Stop counting once past the budget: an unbounded Int would wrap negative after
            // ~2^31 hostile events and silently re-open retention.
            if (untrustedEntries <= MAX_UNTRUSTED_ENTRIES) untrustedEntries += 1
            untrustedEntries
        }
        when {
            retain < MAX_UNTRUSTED_ENTRIES -> w(tag, message)
            retain == MAX_UNTRUSTED_ENTRIES ->
                w(tag, "Further pre-session diagnostics are logcat-only until a session is established")
            // Redact here too: this branch bypasses record(), and the invariant is that nothing
            // unredacted is ever emitted, logcat included.
            else -> emit { Log.w(tag, redact(message)) }
        }
    }

    /** Restores the [untrusted] budget. Call only once a peer has genuinely authenticated. */
    fun clearUntrustedBudget() {
        synchronized(lock) { untrustedEntries = 0 }
    }

    /**
     * Drops any frozen retrieval image. Call when the control connection goes away: an abandoned
     * fetch would otherwise pin a second copy of the ring for the life of the process.
     */
    fun releaseSnapshot() {
        synchronized(lock) { snapshot = null }
    }

    /**
     * Reads one chunk of the current retrieval, or null when [requestedOffset] continues a
     * retrieval whose frozen image is gone -- already drained, or lost with the hosting process.
     * (This is a process-scoped singleton, so restarting `CastServerService` alone does not clear
     * it.) Splicing that offset into a freshly frozen image would silently hand back a torn log:
     * every offset in the response would still be self-consistent against the new image, so the
     * sender could not tell. The caller must surface an error and let the sender restart at 0.
     */
    fun readChunk(requestedOffset: Long, requestedBytes: Int): JsonObject? = synchronized(lock) {
        val offset = requestedOffset.coerceAtLeast(0L)
        val chunkLimit = requestedBytes.coerceIn(1, MAX_CHUNK_BYTES)
        val cached = snapshot
        if (offset > 0L && cached == null) return@synchronized null
        // offset == 0 always starts a new retrieval and re-freezes, even if an abandoned image is
        // still around; a continuation reuses the image frozen then.
        val bytes = if (offset == 0L) freeze() else cached!!
        val safeOffset = offset.coerceAtMost(bytes.size.toLong()).toInt()
        var end = min(bytes.size, safeOffset + chunkLimit)
        while (end > safeOffset && end < bytes.size && isContinuationByte(bytes[end])) {
            end -= 1
        }
        if (end == safeOffset && safeOffset < bytes.size) {
            // The requested budget was smaller than the character sitting at this offset. Emit the
            // whole character anyway: returning an empty non-EOF chunk would leave a client that
            // honours nextOffset spinning forever.
            end = safeOffset + 1
            while (end < bytes.size && isContinuationByte(bytes[end])) end += 1
        }
        val eof = end >= bytes.size
        // Release the frozen image once the sender has drained it.
        if (eof) snapshot = null
        buildJsonObject {
            put("ok", true)
            put("format", "text")
            put("offset", safeOffset.toLong())
            put("nextOffset", end.toLong())
            put("totalBytes", bytes.size.toLong())
            put("eof", eof)
            put("data", String(bytes, safeOffset, end - safeOffset, StandardCharsets.UTF_8))
        }
    }

    @VisibleForTesting
    fun reset() {
        synchronized(lock) {
            entries.clear()
            totalBytes = 0
            untrustedEntries = 0
            snapshot = null
        }
    }

    private fun freeze(): ByteArray =
        entries.joinToString(separator = "").toByteArray(StandardCharsets.UTF_8)
            .also { snapshot = it }

    private fun record(priority: Int, level: String, tag: String, message: String, error: Throwable?) {
        // Redact before anything is emitted: the retained copy leaves the device over the control
        // connection, and logcat is no place for bearer credentials either.
        val safeMessage = redact(message)
        val safeTrace = error?.let { redact(it.stackTraceToString()) }
        emit {
            val logged = if (safeTrace == null) safeMessage else "$safeMessage\n$safeTrace"
            Log.println(priority, tag, logged)
        }
        append(level, tag, safeMessage, safeTrace)
    }

    private fun append(level: String, tag: String, message: String, stackTrace: String?) {
        val detail = buildString {
            append(System.currentTimeMillis())
            append(' ')
            append(level)
            append('/')
            append(tag)
            append(": ")
            append(message)
            if (stackTrace != null) {
                append('\n')
                append(stackTrace)
            }
            append('\n')
        }
        val bytes = detail.toByteArray(StandardCharsets.UTF_8)
        val bounded = if (bytes.size <= MAX_ENTRY_BYTES) {
            detail
        } else {
            var end = MAX_ENTRY_BYTES
            while (end > 0 && isContinuationByte(bytes[end])) end -= 1
            String(bytes, 0, end, StandardCharsets.UTF_8) + "... [entry truncated]\n"
        }
        val boundedBytes = bounded.toByteArray(StandardCharsets.UTF_8).size
        synchronized(lock) {
            entries.addLast(bounded)
            totalBytes += boundedBytes
            while (totalBytes > MAX_BYTES && entries.isNotEmpty()) {
                totalBytes -= entries.removeFirst().toByteArray(StandardCharsets.UTF_8).size
            }
        }
    }

    private fun redact(input: String): String {
        if (privateKeyPattern.containsMatchIn(input)) return "[PRIVATE_KEY_REDACTED]"
        var output = sensitiveFieldPattern.replace(input) { match ->
            "\"…${match.groupValues[1]}\":\"[REDACTED]\""
        }
        output = bearerPattern.replace(output, "Bearer [REDACTED]")
        output = cookiePattern.replace(output, "Cookie: [REDACTED]")
        return urlPattern.replace(output) { match ->
            "${match.groupValues[1]}://${match.groupValues[2]}/[REDACTED]"
        }
    }

    /** True when [byte] is a UTF-8 continuation byte, i.e. splitting here would break a character. */
    private fun isContinuationByte(byte: Byte): Boolean = (byte.toInt() and 0xc0) == 0x80

    private inline fun emit(write: () -> Unit) {
        try {
            write()
        } catch (_: RuntimeException) {
            // Android Log is unavailable in local JVM unit tests; retain the in-memory entry.
        }
    }
}
