package com.iflytek.lanmediacast.receiver.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ReceiverLogTest {
    @Before
    fun setUp() {
        ReceiverLog.reset()
    }

    private fun read(offset: Long, requestedBytes: Int): JsonObject =
        requireNotNull(ReceiverLog.readChunk(offset, requestedBytes)) {
            "expected a log chunk at offset $offset"
        }

    private fun JsonObject.data(): String = this["data"]?.jsonPrimitive?.content.orEmpty()
    private fun JsonObject.offset(): Long = this["offset"]?.jsonPrimitive?.longOrNull ?: -1L
    private fun JsonObject.nextOffset(): Long = this["nextOffset"]?.jsonPrimitive?.longOrNull ?: -1L
    private fun JsonObject.totalBytes(): Long = this["totalBytes"]?.jsonPrimitive?.longOrNull ?: -1L
    private fun JsonObject.eof(): Boolean = this["eof"]?.jsonPrimitive?.booleanOrNull ?: false

    @Test
    fun `log chunks are bounded and continue from the reported offset`() {
        ReceiverLog.i("ReceiverLogTest", "chunk-marker")

        val first = read(0, 64)
        assertEquals(0L, first.offset())
        assertTrue(first.nextOffset() > first.offset() || first.eof())
        assertTrue(first.data().toByteArray(Charsets.UTF_8).size <= 16 * 1024)

        val next = read(if (first.eof()) 0L else first.nextOffset(), 16 * 1024)
        assertTrue(next.offset() >= 0L)
    }

    @Test
    fun `a retrieval reads one consistent snapshot even while new entries arrive`() {
        repeat(400) { index -> ReceiverLog.i("ReceiverLogTest", "seed entry $index") }

        val chunks = StringBuilder()
        var offset = 0L
        var totalBytes = -1L
        var guard = 0
        while (guard++ < 128) {
            val chunk = read(offset, 512)
            assertEquals("chunk offset must match the requested offset", offset, chunk.offset())
            if (totalBytes < 0) {
                totalBytes = chunk.totalBytes()
            } else {
                // The buffer keeps moving underneath, but the frozen image must not.
                assertEquals(totalBytes, chunk.totalBytes())
            }
            chunks.append(chunk.data())
            if (chunk.eof()) break
            assertTrue(chunk.nextOffset() > offset)
            offset = chunk.nextOffset()
            // Simulate the churn a real fetch causes: handling a chunk request itself logs a line.
            ReceiverLog.i("ReceiverLogTest", "noise while reading at $offset")
        }

        val assembled = chunks.toString()
        assertEquals(totalBytes, assembled.toByteArray(Charsets.UTF_8).size.toLong())
        assertFalse("entries must not be torn by eviction", assembled.contains('�'))
        assertTrue(assembled.contains("seed entry 399"))
        // Noise logged after the snapshot was frozen must not appear in this retrieval.
        assertFalse(assembled.contains("noise while reading"))
    }

    @Test
    fun `a continuation with no live snapshot is refused instead of spliced`() {
        ReceiverLog.i("ReceiverLogTest", "entry")

        // Draining the retrieval releases the frozen image.
        val drained = read(0, 16 * 1024)
        assertTrue(drained.eof())

        // Continuing now would have to read a different buffer; the caller must be told to restart
        // rather than handed a silently spliced log.
        assertNull(ReceiverLog.readChunk(drained.nextOffset(), 16 * 1024))
        assertNotNull("restarting at offset 0 must work", ReceiverLog.readChunk(0, 16 * 1024))
    }

    @Test
    fun `credentials are redacted before entries are retained`() {
        ReceiverLog.i("ReceiverLogTest", "Authorization: Bearer abc.def.ghi")
        ReceiverLog.i("ReceiverLogTest", "range https://192.168.1.7:8443/media/1?token=secret")

        val retained = read(0, 16 * 1024).data()
        assertFalse(retained.contains("abc.def.ghi"))
        assertTrue(retained.contains("Bearer [REDACTED]"))
        assertFalse(retained.contains("token=secret"))
        // The host stays readable so the log is still useful for diagnosing routing.
        assertTrue(retained.contains("https://192.168.1.7:8443/[REDACTED]"))
    }

    @Test
    fun `credential fields quoted out of a rejected frame are redacted`() {
        // Decode failures embed the offending input, so a malformed session.hello can carry a
        // peer's token into a buffer that a different, later-paired sender can retrieve.
        ReceiverLog.w(
            "ReceiverLogTest",
            """Rejected sender message: detail=Malformed JSON envelope: {"trustedToken":"s3cr3t-token-value","v":1""",
        )

        val retained = read(0, 16 * 1024).data()
        assertFalse(retained.contains("s3cr3t-token-value"))
        assertTrue(retained.contains("[REDACTED]"))
    }

    @Test
    fun `a credential survives neither a clipped key nor an unusual PEM header`() {
        // Decoder errors minify the offending frame to a window around the failure offset, which
        // routinely clips the front of the key. Redaction must not depend on seeing it intact.
        ReceiverLog.w("ReceiverLogTest", """detail=... JSON input: .....ustedToken":"SECRET_ONE""")
        ReceiverLog.w("ReceiverLogTest", """{"authorization":"SECRET_TWO"}""")
        ReceiverLog.w("ReceiverLogTest", "-----BEGIN RSA PRIVATE KEY-----\nSECRET_THREE\n")

        val retained = read(0, 16 * 1024).data()
        assertFalse("clipped key must still redact", retained.contains("SECRET_ONE"))
        assertFalse(retained.contains("SECRET_TWO"))
        assertFalse("non-PKCS8 PEM headers must redact too", retained.contains("SECRET_THREE"))
    }

    @Test
    fun `pre-session logging is budgeted and restored by a real session`() {
        repeat(200) { index -> ReceiverLog.untrusted("ReceiverLogTest", "pre-session noise $index") }
        // An unauthenticated peer must not be able to push a legitimate entry out of the ring.
        ReceiverLog.i("ReceiverLogTest", "genuine diagnostic")

        val flooded = read(0, 16 * 1024).data()
        assertTrue(flooded.contains("genuine diagnostic"))
        assertFalse("the budget must cap retained pre-session noise", flooded.contains("noise 199"))

        // Establishing a session restores the allowance.
        ReceiverLog.clearUntrustedBudget()
        ReceiverLog.untrusted("ReceiverLogTest", "noise after a real session")
        assertTrue(read(0, 16 * 1024).data().contains("noise after a real session"))
    }

    @Test
    fun `a chunk smaller than one character still makes progress`() {
        ReceiverLog.i("ReceiverLogTest", "中文")

        // Locate the 3-byte character; the entry starts with an ASCII timestamp, so offset 0
        // would not exercise the backoff at all.
        val full = read(0, 16 * 1024).data()
        val cjkOffset = full.substringBefore("中").toByteArray(Charsets.UTF_8).size.toLong()
        assertTrue(cjkOffset > 0L)

        // Start a retrieval that stops short of EOF so the snapshot stays frozen, then ask for
        // less than one character. An empty non-EOF chunk would spin a client following nextOffset.
        read(0, 4)
        val chunk = read(cjkOffset, 1)
        assertEquals(cjkOffset, chunk.offset())
        assertTrue("nextOffset must advance", chunk.nextOffset() > chunk.offset())
        assertEquals("中", chunk.data())
    }

    @Test
    fun `oversized entries are truncated on a character boundary`() {
        ReceiverLog.i("ReceiverLogTest", "中".repeat(8 * 1024))

        val retained = read(0, 16 * 1024).data()
        assertTrue(retained.contains("[entry truncated]"))
        assertFalse("truncation must not split a character", retained.contains('�'))
    }
}
