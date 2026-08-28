package com.iflytek.lanmediacast.receiver.photo

import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.core.ReceiverUiState
import com.iflytek.lanmediacast.receiver.protocol.PhotoChunkCodec
import com.iflytek.lanmediacast.receiver.protocol.PhotoChunkFrame
import com.iflytek.lanmediacast.receiver.protocol.ProtocolCodec
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PhotoExplainCoordinatorTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `batch and photo identifiers cannot escape cache root`() {
        val root = temporaryFolder.newFolder("photo-cache")
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            val result = coordinator.handleCommand(
                "photo.batch.start",
                buildJsonObject {
                    put("batchId", "..")
                    put("revision", 1)
                    put("count", 1)
                    put("photoIds", buildJsonArray { add(JsonPrimitive("../outside")) })
                },
            )
            assertEquals(
                "invalid_message",
                result?.payload?.get("error")?.jsonObject?.get("code")?.jsonPrimitive?.content,
            )
            assertEquals(emptyList<File>(), root.listFiles().orEmpty().filter(File::isDirectory))
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `external path in restored state is rejected without deleting target`() {
        val root = temporaryFolder.newFolder("restore-cache")
        val outside = temporaryFolder.newFile("outside.jpg").apply { writeText("keep") }
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val state = buildJsonObject {
            put("batchId", batchId)
            put("revision", 1)
            put("updatedAt", System.currentTimeMillis())
            put("order", buildJsonArray { add(JsonPrimitive(photoId)) })
            put("removedPhotoIds", buildJsonArray {})
            put("slots", buildJsonArray {
                add(buildJsonObject {
                    put("photoId", photoId)
                    put("transferId", null as String?)
                    put("temporaryPath", null as String?)
                    put("finalPath", outside.absolutePath)
                    put("expectedSize", outside.length())
                    put("expectedSha256", null as String?)
                    put("chunkCount", 1)
                    put("nextChunkIndex", 1)
                    put("mime", "image/jpeg")
                    put("removed", false)
                })
            })
        }
        File(root, "active_batch.json").writeText(
            ProtocolCodec.json.encodeToString(JsonObject.serializer(), state),
            Charsets.UTF_8,
        )

        PhotoExplainCoordinator(root) { _, _ -> }.close()

        assertTrue(outside.isFile)
        assertEquals("keep", outside.readText())
        assertFalse(File(root, "active_batch.json").exists())
    }

    @Test
    fun `restored transfer acknowledges after 32 new chunks from non-aligned index`() {
        val root = temporaryFolder.newFolder("resume-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val transferId = UUID.randomUUID()
        val payload = ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE) { 7 }
        val chunkCount = 40
        val expectedSize = payload.size.toLong() * chunkCount

        val first = PhotoExplainCoordinator(root) { _, _ -> }
        startTransfer(first, batchId, photoId, transferId, expectedSize, chunkCount)
        repeat(5) { index -> first.handleBinary(frame(transferId, index, payload)) }
        first.close()

        val events = CopyOnWriteArrayList<Pair<String, JsonObject>>()
        val restored = PhotoExplainCoordinator(root) { type, value -> events += type to value }
        try {
            repeat(32) { offset ->
                restored.handleBinary(frame(transferId, 5 + offset, payload))
            }
            val deadline = System.currentTimeMillis() + 2_000
            while (
                events.none { (type, value) ->
                    type == "photo.chunk.ack" && value["nextChunkIndex"]?.jsonPrimitive?.int == 37
                } && System.currentTimeMillis() < deadline
            ) {
                Thread.sleep(10)
            }
            assertTrue(
                events.any { (type, value) ->
                    type == "photo.chunk.ack" && value["nextChunkIndex"]?.jsonPrimitive?.int == 37
                },
            )
        } finally {
            restored.close()
        }
    }

    @Test
    fun `failed transfer resumes as awaiting meta without stale transfer identity`() {
        val root = temporaryFolder.newFolder("failed-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val transferId = UUID.randomUUID()
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            startTransfer(
                coordinator,
                batchId,
                photoId,
                transferId,
                PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2,
                2,
            )
            coordinator.handleBinary(
                frame(transferId, 1, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE)),
            )
            val state = coordinator.handleCommand(
                "photo.batch.resume.query",
                buildJsonObject { put("batchId", batchId) },
            )?.payload
            val item = state?.get("items")?.jsonArray?.single()?.jsonObject
            assertEquals("awaitingMeta", item?.get("status")?.jsonPrimitive?.content)
            assertTrue(item?.get("transferId")?.jsonPrimitive?.contentOrNull == null)
            assertTrue(item?.get("nextChunkIndex")?.jsonPrimitive?.contentOrNull == null)
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `duplicate chunk is discarded and re-acknowledged without failing transfer`() {
        val root = temporaryFolder.newFolder("duplicate-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val transferId = UUID.randomUUID()
        val events = CopyOnWriteArrayList<Pair<String, JsonObject>>()
        val coordinator = PhotoExplainCoordinator(root) { type, value -> events += type to value }
        try {
            startTransfer(
                coordinator,
                batchId,
                photoId,
                transferId,
                PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2,
                2,
            )
            val first = frame(transferId, 0, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE))
            coordinator.handleBinary(first)
            coordinator.handleBinary(frame(transferId, 0, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE)))

            val deadline = System.currentTimeMillis() + 2_000
            while (
                events.none { (type, value) ->
                    type == "photo.chunk.ack" && value["nextChunkIndex"]?.jsonPrimitive?.int == 1
                } && System.currentTimeMillis() < deadline
            ) {
                Thread.sleep(10)
            }
            assertTrue(events.none { it.first == "photo.item.failed" })
            val state = coordinator.handleCommand(
                "photo.batch.resume.query",
                buildJsonObject { put("batchId", batchId) },
            )?.payload
            val item = state?.get("items")?.jsonArray?.single()?.jsonObject
            assertEquals("partial", item?.get("status")?.jsonPrimitive?.content)
            assertEquals(1, item?.get("nextChunkIndex")?.jsonPrimitive?.int)
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `trailing frame for failed transfer is silently dropped by tombstone`() {
        val root = temporaryFolder.newFolder("tombstone-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val transferId = UUID.randomUUID()
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            startTransfer(
                coordinator,
                batchId,
                photoId,
                transferId,
                PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2,
                2,
            )
            coordinator.handleBinary(
                frame(transferId, 1, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE)),
            )
            coordinator.handleBinary(
                frame(transferId, 0, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE)),
            )
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `queued ack callback runs without coordinator monitor`() {
        val root = temporaryFolder.newFolder("event-lock-cache")
        val callback = CountDownLatch(1)
        val callbackHeldCoordinatorLock = AtomicBoolean(true)
        lateinit var coordinator: PhotoExplainCoordinator
        coordinator = PhotoExplainCoordinator(root) { _, _ ->
            callbackHeldCoordinatorLock.set(Thread.holdsLock(coordinator))
            callback.countDown()
        }
        try {
            val batchId = UUID.randomUUID().toString()
            val photoId = UUID.randomUUID().toString()
            val transferId = UUID.randomUUID()
            startTransfer(
                coordinator,
                batchId,
                photoId,
                transferId,
                PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2,
                2,
            )
            coordinator.handleBinary(
                frame(transferId, 0, ByteArray(PhotoChunkCodec.MAX_PAYLOAD_SIZE)),
            )
            assertTrue(callback.await(2, TimeUnit.SECONDS))
            assertFalse(callbackHeldCoordinatorLock.get())
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `batch update removes only listed photo and advances revision`() {
        val root = temporaryFolder.newFolder("batch-update-cache")
        val batchId = UUID.randomUUID().toString()
        val removedId = UUID.randomUUID().toString()
        val retainedId = UUID.randomUUID().toString()
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            coordinator.handleCommand(
                "photo.batch.start",
                buildJsonObject {
                    put("batchId", batchId)
                    put("revision", 1)
                    put("count", 2)
                    put("photoIds", buildJsonArray {
                        add(JsonPrimitive(removedId))
                        add(JsonPrimitive(retainedId))
                    })
                },
            )
            assertEquals(
                listOf(removedId, retainedId),
                ReceiverRuntime.state.photoSlots.map { it.photoId },
            )
            assertTrue(ReceiverRuntime.state.photoSlots.all { it.path == null })
            val update = coordinator.handleCommand(
                "photo.batch.update",
                buildJsonObject {
                    put("batchId", batchId)
                    put("revision", 2)
                    put("removedPhotoIds", buildJsonArray { add(JsonPrimitive(removedId)) })
                },
            )
            assertEquals("true", update?.payload?.get("ok")?.jsonPrimitive?.content)

            val state = coordinator.handleCommand(
                "photo.batch.resume.query",
                buildJsonObject { put("batchId", batchId) },
            )?.payload
            assertEquals(2, state?.get("revision")?.jsonPrimitive?.int)
            assertEquals(
                listOf(removedId),
                state?.get("removedPhotoIds")?.jsonArray?.map { it.jsonPrimitive.content },
            )
            val statuses = state?.get("items")?.jsonArray?.associate { item ->
                val value = item.jsonObject
                value.getValue("photoId").jsonPrimitive.content to
                    value.getValue("status").jsonPrimitive.content
            }
            assertEquals("removed", statuses?.get(removedId))
            assertEquals("awaitingMeta", statuses?.get(retainedId))
            assertEquals(
                listOf(retainedId),
                ReceiverRuntime.state.photoSlots.map { it.photoId },
            )
        } finally {
            coordinator.close()
            ReceiverRuntime.update { ReceiverUiState() }
        }
    }

    @Test
    fun `inconsistent photo metadata is invalid message rather than storage low`() {
        val root = temporaryFolder.newFolder("invalid-meta-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            coordinator.handleCommand(
                "photo.batch.start",
                buildJsonObject {
                    put("batchId", batchId)
                    put("revision", 1)
                    put("count", 1)
                    put("photoIds", buildJsonArray { add(JsonPrimitive(photoId)) })
                },
            )
            val result = coordinator.handleCommand(
                "photo.item.meta",
                buildJsonObject {
                    put("batchId", batchId)
                    put("revision", 1)
                    put("photoId", photoId)
                    put("transferId", UUID.randomUUID().toString())
                    put("size", 1)
                    put("chunkCount", 2)
                    put("sha256", "unused")
                    put("mime", "image/jpeg")
                },
            )
            assertEquals(
                "invalid_message",
                result?.payload?.get("error")?.jsonObject?.get("code")?.jsonPrimitive?.content,
            )
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `malformed replacement metadata leaves active transfer unchanged`() {
        val root = temporaryFolder.newFolder("transactional-meta-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val originalTransferId = UUID.randomUUID()
        val coordinator = PhotoExplainCoordinator(root) { _, _ -> }
        try {
            startTransfer(
                coordinator,
                batchId,
                photoId,
                originalTransferId,
                PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2,
                2,
            )
            val malformed = coordinator.handleCommand(
                "photo.item.meta",
                buildJsonObject {
                    put("batchId", batchId)
                    put("revision", 1)
                    put("photoId", photoId)
                    put("transferId", UUID.randomUUID().toString())
                    put("size", PhotoChunkCodec.MAX_PAYLOAD_SIZE.toLong() * 2)
                    put("chunkCount", 2)
                    put("sha256", "unused")
                },
            )
            assertEquals(
                "invalid_message",
                malformed?.payload?.get("error")?.jsonObject?.get("code")?.jsonPrimitive?.content,
            )
            val state = coordinator.handleCommand(
                "photo.batch.resume.query",
                buildJsonObject { put("batchId", batchId) },
            )?.payload
            val item = state?.get("items")?.jsonArray?.single()?.jsonObject
            assertEquals("ready", item?.get("status")?.jsonPrimitive?.content)
            assertEquals(
                originalTransferId.toString(),
                item?.get("transferId")?.jsonPrimitive?.content,
            )
        } finally {
            coordinator.close()
        }
    }

    @Test
    fun `digest failure after final ack emits item failed and resets slot`() {
        val root = temporaryFolder.newFolder("digest-failure-cache")
        val batchId = UUID.randomUUID().toString()
        val photoId = UUID.randomUUID().toString()
        val transferId = UUID.randomUUID()
        val events = CopyOnWriteArrayList<Pair<String, JsonObject>>()
        val failed = CountDownLatch(1)
        val coordinator = PhotoExplainCoordinator(
            root,
            encodeDigest = { "actual-digest" },
        ) { type, value ->
            events += type to value
            if (type == "photo.item.failed") failed.countDown()
        }
        try {
            startTransfer(
                coordinator,
                batchId,
                photoId,
                transferId,
                expectedSize = 3,
                chunkCount = 1,
                sha256 = "declared-digest",
            )
            coordinator.handleBinary(
                ByteBuffer.wrap(
                    PhotoChunkCodec.encode(
                        PhotoChunkFrame(
                            transferId = transferId,
                            chunkIndex = 0,
                            isLast = true,
                            payload = byteArrayOf(1, 2, 3),
                        ),
                    ),
                ),
            )
            assertTrue(failed.await(2, TimeUnit.SECONDS))
            assertEquals(
                listOf("photo.chunk.ack", "photo.item.failed"),
                events.map { it.first }.filter { it == "photo.chunk.ack" || it == "photo.item.failed" },
            )
            val state = coordinator.handleCommand(
                "photo.batch.resume.query",
                buildJsonObject { put("batchId", batchId) },
            )?.payload
            val item = state?.get("items")?.jsonArray?.single()?.jsonObject
            assertEquals("awaitingMeta", item?.get("status")?.jsonPrimitive?.content)
            assertTrue(item?.get("transferId")?.jsonPrimitive?.contentOrNull == null)
        } finally {
            coordinator.close()
        }
    }

    private fun startTransfer(
        coordinator: PhotoExplainCoordinator,
        batchId: String,
        photoId: String,
        transferId: UUID,
        expectedSize: Long,
        chunkCount: Int,
        sha256: String = "unused",
    ) {
        coordinator.handleCommand(
            "photo.batch.start",
            buildJsonObject {
                put("batchId", batchId)
                put("revision", 1)
                put("count", 1)
                put("photoIds", buildJsonArray { add(JsonPrimitive(photoId)) })
            },
        )
        val ready = coordinator.handleCommand(
            "photo.item.meta",
            buildJsonObject {
                put("batchId", batchId)
                put("revision", 1)
                put("photoId", photoId)
                put("transferId", transferId.toString())
                put("size", expectedSize)
                put("chunkCount", chunkCount)
                put("sha256", sha256)
                put("mime", "image/jpeg")
            },
        )
        assertEquals(
            "Unexpected photo.item.meta response: ${ready?.payload}",
            true,
            ready?.payload?.get("ok")?.jsonPrimitive?.content?.toBooleanStrict(),
        )
    }

    private fun frame(transferId: UUID, index: Int, payload: ByteArray): ByteBuffer = ByteBuffer.wrap(
        PhotoChunkCodec.encode(
            PhotoChunkFrame(
                transferId = transferId,
                chunkIndex = index.toLong(),
                isLast = false,
                payload = payload,
            ),
        ),
    )
}
