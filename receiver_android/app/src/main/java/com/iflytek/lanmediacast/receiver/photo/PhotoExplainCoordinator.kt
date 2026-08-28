package com.iflytek.lanmediacast.receiver.photo

import android.content.Context
import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.core.PhotoSlotUiState
import com.iflytek.lanmediacast.receiver.protocol.PhotoChunkCodec
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import com.iflytek.lanmediacast.receiver.protocol.ProtocolCodec

data class PhotoCommandResult(val responseType: String, val payload: JsonObject)

class PhotoBinaryException(
    val reason: String,
    val transferId: String?,
    val closeConnection: Boolean,
) : IllegalArgumentException(reason)

class PhotoExplainCoordinator internal constructor(
    private val root: File,
    private val encodeDigest: (ByteArray) -> String = { digest ->
        android.util.Base64.encodeToString(
            digest,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
        )
    },
    private val emitCallback: (String, JsonObject) -> Unit,
) : AutoCloseable {
    constructor(context: Context, emit: (String, JsonObject) -> Unit) :
        this(File(context.filesDir, "photo_cache"), emitCallback = emit)

    private data class Slot(
        val photoId: String,
        var transferId: String? = null,
        var file: File? = null,
        var finalFile: File? = null,
        var expectedSize: Long = 0,
        var expectedSha256: String? = null,
        var chunkCount: Int = 0,
        var nextChunkIndex: Int = 0,
        var mime: String = "image/jpeg",
        var output: FileOutputStream? = null,
        var chunksSinceLastAck: Int = 0,
        var lastAckedChunkIndex: Int = 0,
        var pendingAck: ScheduledFuture<*>? = null,
        var forceAck: Boolean = false,
        var duplicateCount: Int = 0,
        var duplicateWindowStartedAt: Long = 0,
        var lastProgressAt: Long = 0,
        var removed: Boolean = false,
    )

    private data class Batch(
        val batchId: String,
        var revision: Long,
        val order: MutableList<String>,
        val slots: MutableMap<String, Slot>,
        val removedPhotoIds: MutableSet<String>,
        var updatedAt: Long,
    )

    private data class Tombstone(
        val createdAt: Long,
        var trailingFrames: Int = 0,
    )

    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "photo-ack").apply { isDaemon = true }
    }
    private val eventExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "photo-events").apply { isDaemon = true }
    }
    private val rootPath: String
    private var batch: Batch? = null
    private val transfers = mutableMapOf<String, Slot>()
    private val tombstones = linkedMapOf<String, Tombstone>()
    private var unknownWindowStartedAt = 0L
    private var unknownFrameCount = 0

    init {
        check(root.mkdirs() || root.isDirectory) { "Photo cache root is unavailable" }
        rootPath = root.canonicalPath
        cleanupExpiredParts()
        restoreState()
        cleanupCompletedBatches()
    }

    @Synchronized
    fun handleCommand(type: String, payload: JsonObject): PhotoCommandResult? {
        expireStaleBatch()
        return when (type) {
            "photo.batch.start" -> startBatch(payload)
            "photo.batch.update" -> updateBatch(payload)
            "photo.item.meta" -> startItem(payload)
            "photo.batch.cancel" -> cancelBatch(payload)
            "photo.batch.resume.query" -> resumeState(payload)
            "photo.operation" -> operation(payload)
            else -> null
        }
    }

    @Synchronized
    fun beginConnection() {
        tombstones.clear()
        unknownWindowStartedAt = 0
        unknownFrameCount = 0
    }

    @Synchronized
    fun handleBinary(frame: ByteBuffer) {
        val bytes = ByteArray(frame.remaining()).also(frame::get)
        val decoded = try {
            PhotoChunkCodec.decode(bytes)
        } catch (_: IllegalArgumentException) {
            throw PhotoBinaryException("malformed_binary_header", null, true)
        }
        val transferId = decoded.transferId.toString()
        val slotBeforeExpiry = transfers[transferId]
        try {
            expireStaleBatch()
        } catch (_: Exception) {
            if (slotBeforeExpiry != null) {
                failSlot(slotBeforeExpiry, "write_failed")
                return
            }
            throw PhotoBinaryException("internal_error", transferId, false)
        }
        cleanupTombstones()
        val slot = transfers[transferId]
        if (slot == null) {
            val tombstone = tombstones[transferId]
                ?: throw PhotoBinaryException(
                    "unknown_transfer",
                    transferId,
                    recordUnknownFrame(),
                )
            tombstone.trailingFrames += 1
            if (tombstone.trailingFrames > MAX_TOMBSTONE_FRAMES) {
                throw PhotoBinaryException("unknown_transfer", transferId, true)
            }
            return
        }
        if (decoded.chunkIndex < slot.nextChunkIndex.toLong()) {
            handleDuplicate(transferId, slot)
            return
        }
        if (decoded.chunkIndex > slot.nextChunkIndex.toLong()) {
            failSlot(slot, "invalid_message")
            return
        }
        if (decoded.isLast != (slot.nextChunkIndex == slot.chunkCount - 1)) {
            failSlot(slot, "invalid_message")
            return
        }
        val expectedPayloadSize = if (decoded.isLast) {
            (slot.expectedSize - decoded.chunkIndex * MAX_PAYLOAD).toInt()
        } else {
            MAX_PAYLOAD
        }
        if (decoded.payload.size != expectedPayloadSize) {
            failSlot(slot, "invalid_message")
            return
        }
        try {
            slot.output?.write(decoded.payload)
                ?: throw PhotoBinaryException("unknown_transfer", transferId, false)
            slot.nextChunkIndex += 1
            slot.chunksSinceLastAck += 1
            slot.duplicateCount = 0
            slot.duplicateWindowStartedAt = 0
            slot.lastProgressAt = System.currentTimeMillis()
            saveState()
            if (slot.chunksSinceLastAck >= ACK_WINDOW || decoded.isLast) {
                if (!emitAckNow(transferId, slot)) return
            } else {
                scheduleAck(transferId, slot)
            }
            if (decoded.isLast) completeSlot(slot)
        } catch (_: IOException) {
            failSlot(slot, "write_failed")
        } catch (_: IllegalStateException) {
            failSlot(slot, "write_failed")
        } catch (_: SecurityException) {
            failSlot(slot, "write_failed")
        }
    }

    private fun startBatch(payload: JsonObject): PhotoCommandResult {
        val batchId = payload.string("batchId")
        val revision = payload.long("revision")
        val ids = payload["photoIds"]?.jsonArray?.map { it.jsonPrimitive.content }
            ?: return errorResult("photo.batch.ready", "invalid_message", "photoIds is required")
        val count = payload["count"]?.jsonPrimitive?.intOrNull
        if (!isUuid(batchId) || revision < 0) {
            return errorResult("photo.batch.ready", "invalid_message", "Batch identity or revision is invalid")
        }
        if (
            count == null || count !in 1..9 || ids.size != count || ids.distinct().size != ids.size ||
            ids.any { !isUuid(it) }
        ) {
            return errorResult("photo.batch.ready", "invalid_message", "Photo batch must contain 1-9 unique items")
        }
        closeBatch(deleteFiles = false)
        val directory = batchDirectory(batchId)
        if (!directory.mkdirs() && !directory.isDirectory) {
            return errorResult("photo.batch.ready", "write_failed", "Photo batch directory is unavailable")
        }
        val slots = ids.associateWith { Slot(it) }.toMutableMap()
        batch = Batch(
            batchId,
            revision,
            ids.toMutableList(),
            slots,
            mutableSetOf(),
            System.currentTimeMillis(),
        )
        saveState()
        publishPhotos()
        return PhotoCommandResult("photo.batch.ready", buildJsonObject {
            put("ok", true); put("batchId", batchId); put("revision", revision)
        })
    }

    private fun startItem(payload: JsonObject): PhotoCommandResult {
        val active = batch ?: return errorResult("photo.item.ready", "item_not_found", "Batch was not found")
        if (payload.string("batchId") != active.batchId || payload.long("revision") != active.revision) {
            return errorResult("photo.item.ready", "revision_conflict", "Batch revision does not match")
        }
        val photoId = payload.string("photoId")
        val slot = active.slots[photoId]
            ?: return errorResult("photo.item.ready", "item_not_found", "Photo slot was not found")
        if (slot.removed) {
            return errorResult("photo.item.ready", "item_not_found", "Photo slot was removed")
        }
        val transferId = payload.string("transferId")
        if (!isUuid(photoId) || !isUuid(transferId)) {
            return errorResult("photo.item.ready", "invalid_message", "transferId is invalid")
        }
        val size = payload.long("size")
        val chunkCount = payload.int("chunkCount")
        val sha256 = payload.string("sha256")
        val mime = payload["mime"]?.jsonPrimitive?.contentOrNull
            ?: return errorResult("photo.item.ready", "invalid_message", "Photo mime is required")
        val committedBatchBytes = active.slots.values
            .filter { it !== slot }
            .sumOf { it.expectedSize }
        val expectedChunkCount = (size + MAX_PAYLOAD - 1) / MAX_PAYLOAD
        if (
            size <= 0 || chunkCount.toLong() != expectedChunkCount ||
            chunkCount <= 0 || chunkCount > MAX_CHUNKS
        ) {
            return errorResult("photo.item.ready", "invalid_message", "Photo size or chunkCount is invalid")
        }
        if (committedBatchBytes + size > MAX_BATCH_BYTES) {
            return errorResult("photo.item.ready", "storage_low", "Photo is too large")
        }
        if (root.usableSpace - STORAGE_RESERVE < size) {
            return errorResult("photo.item.ready", "storage_low", "Not enough storage")
        }
        val directory = batchDirectory(active.batchId).apply {
            check(mkdirs() || isDirectory) { "Photo batch directory is unavailable" }
        }
        val temporary = internalChild(directory, "$photoId.$transferId.part")
        if (transferId in transfers || transferId in tombstones) {
            return errorResult("photo.item.ready", "invalid_message", "transferId is already in use")
        }
        val output = try {
            FileOutputStream(temporary, false)
        } catch (_: IOException) {
            runCatching { deleteInternalFile(temporary) }
            return errorResult("photo.item.ready", "write_failed", "Photo temporary file is unavailable")
        }
        val replacement = Slot(
            photoId = photoId,
            transferId = transferId,
            file = temporary,
            expectedSize = size,
            expectedSha256 = sha256,
            chunkCount = chunkCount,
            mime = mime,
            output = output,
            lastProgressAt = System.currentTimeMillis(),
        )
        active.slots[photoId] = replacement
        transfers[transferId] = replacement
        try {
            saveState()
        } catch (_: IOException) {
            active.slots[photoId] = slot
            transfers.remove(transferId)
            runCatching { output.close() }
            runCatching { deleteInternalFile(temporary) }
            return errorResult("photo.item.ready", "write_failed", "Photo transfer state could not be saved")
        }
        cancelPendingAck(slot)
        runCatching { slot.output?.close() }
        slot.transferId?.let {
            transfers.remove(it)
            addTombstone(it)
        }
        slot.file?.let { runCatching { deleteInternalFile(it) } }
        slot.finalFile?.let { runCatching { deleteInternalFile(it) } }
        return PhotoCommandResult("photo.item.ready", buildJsonObject {
            put("ok", true)
            put("batchId", active.batchId)
            put("photoId", photoId)
            put("transferId", transferId)
            put("nextChunkIndex", 0)
        })
    }

    private fun updateBatch(payload: JsonObject): PhotoCommandResult {
        val active = batch ?: return errorResult("response", "item_not_found", "Batch was not found")
        if (payload.string("batchId") != active.batchId) {
            return errorResult("response", "item_not_found", "Batch was not found")
        }
        val revision = payload.long("revision")
        if (revision <= active.revision) {
            return errorResult("response", "revision_conflict", "Batch revision must increase")
        }
        val removedIds = payload["removedPhotoIds"]?.jsonArray?.map { it.jsonPrimitive.content }
            ?: return errorResult("response", "invalid_message", "removedPhotoIds is required")
        if (removedIds.distinct().size != removedIds.size || removedIds.any { !isUuid(it) || it !in active.slots }) {
            return errorResult("response", "invalid_message", "removedPhotoIds is invalid")
        }
        removedIds.forEach { photoId ->
            val slot = active.slots.getValue(photoId)
            cancelPendingAck(slot)
            slot.output?.close()
            slot.output = null
            slot.file?.let(::deleteInternalFile)
            slot.finalFile?.let(::deleteInternalFile)
            slot.transferId?.let {
                transfers.remove(it)
                addTombstone(it)
            }
            slot.transferId = null
            slot.file = null
            slot.finalFile = null
            slot.nextChunkIndex = 0
            slot.chunkCount = 0
            slot.expectedSize = 0
            slot.expectedSha256 = null
            slot.removed = true
            active.removedPhotoIds += photoId
        }
        active.revision = revision
        saveState()
        publishPhotos()
        return PhotoCommandResult("response", ok())
    }

    private fun completeSlot(slot: Slot) {
        cancelPendingAck(slot)
        slot.output?.close()
        slot.output = null
        val temporary = slot.file ?: return
        val digest = MessageDigest.getInstance("SHA-256")
        temporary.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1_024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actualHash = digest.digest()
        val actualText = encodeDigest(actualHash)
        if (temporary.length() != slot.expectedSize || actualText != slot.expectedSha256) {
            failSlot(slot, "transfer_corrupt")
            return
        }
        val extension = when (slot.mime) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> "jpg"
        }
        val finalFile = internalChild(
            temporary.parentFile ?: throw IllegalStateException("Photo temporary directory is missing"),
            "${slot.photoId}.$extension",
        )
        if (finalFile.exists()) deleteInternalFile(finalFile)
        if (!temporary.renameTo(finalFile)) {
            failSlot(slot, "write_failed")
            return
        }
        slot.file = null
        slot.finalFile = finalFile
        slot.transferId?.let {
            transfers.remove(it)
            addTombstone(it)
        }
        saveState()
        queueEvent("photo.item.complete", buildJsonObject {
            put("photoId", slot.photoId)
            put("transferId", slot.transferId ?: "")
        })
        publishPhotos()
        val active = batch
        if (active != null && active.slots.values.all { it.removed || it.finalFile?.isFile == true }) {
            queueEvent("photo.batch.complete", buildJsonObject {
                put("batchId", active.batchId); put("revision", active.revision)
            })
            cleanupCompletedBatches()
        }
    }

    private fun failSlot(slot: Slot, code: String) {
        cancelPendingAck(slot)
        runCatching { slot.output?.close() }
        slot.output = null
        val transferId = slot.transferId
        slot.file?.let { runCatching { deleteInternalFile(it) } }
        slot.finalFile?.let { runCatching { deleteInternalFile(it) } }
        transferId?.let {
            transfers.remove(it)
            addTombstone(it)
        }
        slot.transferId = null
        slot.file = null
        slot.finalFile = null
        slot.nextChunkIndex = 0
        slot.chunkCount = 0
        slot.expectedSize = 0
        slot.expectedSha256 = null
        slot.chunksSinceLastAck = 0
        slot.lastAckedChunkIndex = 0
        slot.forceAck = false
        slot.duplicateCount = 0
        slot.duplicateWindowStartedAt = 0
        slot.lastProgressAt = 0
        runCatching { saveState() }
        queueEvent("photo.item.failed", buildJsonObject {
            put("photoId", slot.photoId)
            put("transferId", transferId ?: "")
            put("errorCode", code)
            put("retryable", false)
            put("attempt", 0)
        })
    }

    private fun cancelBatch(payload: JsonObject): PhotoCommandResult {
        val active = batch
        if (active != null && payload["batchId"]?.jsonPrimitive?.contentOrNull == active.batchId) {
            closeBatch(deleteFiles = true)
            stateFile.delete()
            ReceiverRuntime.update { it.copy(mode = "media", photoPaths = emptyList(), photoSlots = emptyList()) }
        }
        return PhotoCommandResult("response", ok())
    }

    private fun resumeState(payload: JsonObject): PhotoCommandResult {
        val requestedId = payload.string("batchId")
        val active = batch
        val found = active?.batchId == requestedId
        val completed = found && active!!.slots.values.all { it.removed || it.finalFile?.isFile == true }
        return PhotoCommandResult("photo.batch.resume.state", buildJsonObject {
            put("ok", true)
            put("batchId", requestedId)
            put("batchStatus", if (!found) "notFound" else if (completed) "complete" else "active")
            put("revision", if (found) JsonPrimitive(active!!.revision) else JsonPrimitive(null as String?))
            put("removedPhotoIds", if (!found) buildJsonArray {} else buildJsonArray {
                active!!.removedPhotoIds.forEach { add(JsonPrimitive(it)) }
            })
            put("items", if (!found) buildJsonArray {} else buildJsonArray {
                active!!.order.forEach { id ->
                    val slot = active.slots.getValue(id)
                    add(buildJsonObject {
                        put("photoId", id)
                        put("status", when {
                            slot.removed -> "removed"
                            slot.finalFile != null -> "complete"
                            slot.nextChunkIndex > 0 -> "partial"
                            slot.transferId != null -> "ready"
                            else -> "awaitingMeta"
                        })
                        put("transferId", slot.transferId?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
                        put("nextChunkIndex", if (slot.transferId == null) JsonPrimitive(null as String?) else JsonPrimitive(slot.nextChunkIndex))
                    })
                }
            })
        })
    }

    private fun operation(payload: JsonObject): PhotoCommandResult {
        val active = batch ?: return errorResult("response", "item_not_found", "Batch was not found")
        if (payload.string("batchId") != active.batchId || payload.long("revision") != active.revision) {
            return errorResult("response", "revision_conflict", "Batch revision does not match")
        }
        return PhotoCommandResult("response", ok())
    }

    private fun emitAckNow(transferId: String, slot: Slot): Boolean {
        cancelPendingAck(slot)
        try {
            slot.output?.fd?.sync()
        } catch (_: IOException) {
            failSlot(slot, "write_failed")
            return false
        }
        slot.lastAckedChunkIndex = slot.nextChunkIndex
        slot.chunksSinceLastAck = 0
        slot.forceAck = false
        queueEvent("photo.chunk.ack", buildJsonObject {
            put("transferId", transferId); put("nextChunkIndex", slot.nextChunkIndex)
        })
        return true
    }

    private fun queueEvent(type: String, payload: JsonObject) {
        eventExecutor.execute { emitCallback(type, payload) }
    }

    private fun scheduleAck(transferId: String, slot: Slot, force: Boolean = false) {
        if (force) slot.forceAck = true
        if (slot.pendingAck != null) return
        slot.pendingAck = scheduler.schedule({
            synchronized(this@PhotoExplainCoordinator) {
                slot.pendingAck = null
                if (
                    transfers[transferId] === slot &&
                    (slot.nextChunkIndex > slot.lastAckedChunkIndex || slot.forceAck)
                ) {
                    emitAckNow(transferId, slot)
                }
            }
        }, ACK_INTERVAL_MILLIS, TimeUnit.MILLISECONDS)
    }

    private fun cancelPendingAck(slot: Slot) {
        slot.pendingAck?.cancel(false)
        slot.pendingAck = null
    }

    private fun handleDuplicate(transferId: String, slot: Slot) {
        val now = System.currentTimeMillis()
        if (slot.duplicateWindowStartedAt == 0L || now - slot.duplicateWindowStartedAt > DUPLICATE_WINDOW_MILLIS) {
            slot.duplicateWindowStartedAt = now
            slot.duplicateCount = 0
        }
        slot.duplicateCount += 1
        if (
            slot.duplicateCount >= MAX_DUPLICATE_FRAMES ||
            now - slot.lastProgressAt >= DUPLICATE_WINDOW_MILLIS
        ) {
            failSlot(slot, "invalid_message")
            return
        }
        scheduleAck(transferId, slot, force = true)
    }

    private fun publishPhotos() {
        val active = batch ?: return
        val slots = active.order.mapNotNull { photoId ->
            val slot = active.slots[photoId]
            if (slot == null || slot.removed) null else PhotoSlotUiState(photoId, slot.finalFile?.absolutePath)
        }
        val paths = slots.mapNotNull(PhotoSlotUiState::path)
        ReceiverRuntime.update { it.copy(mode = "photo", photoPaths = paths, photoSlots = slots) }
    }

    private fun closeBatch(deleteFiles: Boolean) {
        val active = batch ?: return
        active.slots.values.forEach { slot ->
            cancelPendingAck(slot)
            slot.output?.close()
            slot.transferId?.let(::addTombstone)
            if (deleteFiles) {
                slot.file?.let(::deleteInternalFile)
                slot.finalFile?.let(::deleteInternalFile)
            }
        }
        transfers.clear()
        if (deleteFiles) deleteInternalTree(batchDirectory(active.batchId))
        batch = null
    }

    @Synchronized
    override fun close() {
        closeBatch(deleteFiles = false)
        scheduler.shutdownNow()
        eventExecutor.shutdown()
    }

    private fun saveState() {
        val active = batch ?: return
        val state = buildJsonObject {
            put("batchId", active.batchId)
            put("revision", active.revision)
            active.updatedAt = System.currentTimeMillis()
            put("updatedAt", active.updatedAt)
            put("order", buildJsonArray { active.order.forEach { add(JsonPrimitive(it)) } })
            put("removedPhotoIds", buildJsonArray {
                active.removedPhotoIds.forEach { add(JsonPrimitive(it)) }
            })
            put("slots", buildJsonArray {
                active.order.forEach { id ->
                    val slot = active.slots.getValue(id)
                    add(buildJsonObject {
                        put("photoId", slot.photoId)
                        put("transferId", slot.transferId?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
                        put("temporaryPath", slot.file?.absolutePath?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
                        put("finalPath", slot.finalFile?.absolutePath?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
                        put("expectedSize", slot.expectedSize)
                        put("expectedSha256", slot.expectedSha256?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
                        put("chunkCount", slot.chunkCount)
                        put("nextChunkIndex", slot.nextChunkIndex)
                        put("mime", slot.mime)
                        put("removed", slot.removed)
                    })
                }
            })
        }
        val temporary = File(root, "active_batch.json.tmp")
        temporary.writeText(ProtocolCodec.json.encodeToString(JsonObject.serializer(), state), Charsets.UTF_8)
        if (stateFile.exists()) stateFile.delete()
        if (!temporary.renameTo(stateFile)) {
            temporary.copyTo(stateFile, overwrite = true)
            temporary.delete()
        }
    }

    private fun restoreState() {
        if (!stateFile.isFile) return
        try {
            val state = ProtocolCodec.json.parseToJsonElement(stateFile.readText(Charsets.UTF_8)).jsonObject
            val updatedAt = state.getValue("updatedAt").jsonPrimitive.long
            val batchId = state.getValue("batchId").jsonPrimitive.content
            if (!isUuid(batchId)) throw IllegalStateException("Invalid batchId")
            val directory = batchDirectory(batchId)
            if (System.currentTimeMillis() - updatedAt > RETENTION_MILLIS) {
                val completed = state.getValue("slots").jsonArray.all { element ->
                    internalFile(
                        element.jsonObject["finalPath"]?.jsonPrimitive?.contentOrNull,
                        directory,
                    )?.isFile == true
                }
                if (!completed) deleteInternalTree(directory)
                stateFile.delete()
                return
            }
            val revision = state.getValue("revision").jsonPrimitive.long
            val order = state.getValue("order").jsonArray.map { it.jsonPrimitive.content }.toMutableList()
            if (order.size !in 1..9 || order.distinct().size != order.size) throw IllegalStateException("Invalid order")
            val removedPhotoIds = state["removedPhotoIds"]?.jsonArray
                ?.map { it.jsonPrimitive.content }
                ?.toMutableSet()
                ?: mutableSetOf()
            if (removedPhotoIds.any { !isUuid(it) || it !in order }) {
                throw IllegalStateException("Invalid removedPhotoIds")
            }
            val slots = state.getValue("slots").jsonArray.associate { element ->
                val value = element.jsonObject
                val photoId = value.getValue("photoId").jsonPrimitive.content
                if (!isUuid(photoId)) throw IllegalStateException("Invalid photoId")
                val transferId = value["transferId"]?.jsonPrimitive?.contentOrNull
                if (transferId != null && !isUuid(transferId)) {
                    throw IllegalStateException("Invalid transferId")
                }
                val slot = Slot(
                    photoId = photoId,
                    transferId = transferId,
                    file = internalFile(value["temporaryPath"]?.jsonPrimitive?.contentOrNull, directory),
                    finalFile = internalFile(value["finalPath"]?.jsonPrimitive?.contentOrNull, directory),
                    expectedSize = value.getValue("expectedSize").jsonPrimitive.long,
                    expectedSha256 = value["expectedSha256"]?.jsonPrimitive?.contentOrNull,
                    chunkCount = value.getValue("chunkCount").jsonPrimitive.int,
                    nextChunkIndex = value.getValue("nextChunkIndex").jsonPrimitive.int,
                    mime = value.getValue("mime").jsonPrimitive.content,
                    removed = value["removed"]?.jsonPrimitive?.booleanOrNull ?: false,
                )
                photoId to slot
            }.toMutableMap()
            if (slots.keys != order.toSet()) throw IllegalStateException("Slot order mismatch")
            slots.values.forEach { slot ->
                if (
                    slot.expectedSize < 0 || slot.chunkCount !in 0..MAX_CHUNKS ||
                    slot.nextChunkIndex !in 0..slot.chunkCount
                ) {
                    throw IllegalStateException("Invalid transfer state")
                }
                val finalFile = slot.finalFile
                if (finalFile != null && finalFile.isFile) return@forEach
                slot.finalFile = null
                val temporary = slot.file
                val transferId = slot.transferId
                if (temporary == null || transferId == null || !temporary.isFile || slot.nextChunkIndex < 0) {
                    slot.transferId = null
                    slot.file = null
                    slot.nextChunkIndex = 0
                    return@forEach
                }
                val committedLength = slot.nextChunkIndex.toLong() * MAX_PAYLOAD
                if (temporary.length() < committedLength) throw IllegalStateException("Truncated transfer")
                if (temporary.length() > committedLength) {
                    RandomAccessFile(temporary, "rw").use { it.setLength(committedLength) }
                }
                slot.output = FileOutputStream(temporary, true)
                slot.chunksSinceLastAck = 0
                slot.lastAckedChunkIndex = slot.nextChunkIndex
                slot.lastProgressAt = System.currentTimeMillis()
                transfers[transferId] = slot
            }
            batch = Batch(batchId, revision, order, slots, removedPhotoIds, updatedAt)
            publishPhotos()
        } catch (_: Exception) {
            transfers.values.forEach {
                cancelPendingAck(it)
                it.output?.close()
            }
            transfers.clear()
            batch = null
            stateFile.delete()
        }
    }

    private fun internalFile(path: String?, expectedParent: File? = null): File? {
        if (path == null) return null
        val candidateFile = File(path).canonicalFile
        val candidate = candidateFile.path
        if (candidate != rootPath && !candidate.startsWith(rootPath + File.separator)) {
            throw IllegalStateException("Photo path escaped cache root")
        }
        if (expectedParent != null && candidateFile.parentFile?.canonicalPath != expectedParent.canonicalPath) {
            throw IllegalStateException("Photo path escaped batch directory")
        }
        return candidateFile
    }

    private fun internalChild(parent: File, name: String): File =
        internalFile(File(parent, name).path, parent)
            ?: throw IllegalStateException("Photo path is missing")

    private fun batchDirectory(batchId: String): File {
        check(isUuid(batchId)) { "Invalid batchId" }
        return internalChild(root, batchId)
    }

    private fun deleteInternalFile(file: File) {
        val safe = internalFile(file.path) ?: return
        check(safe.path != rootPath) { "Refusing to delete photo cache root" }
        if (!safe.isDirectory) safe.delete()
    }

    private fun deleteInternalTree(directory: File) {
        val safe = internalFile(directory.path) ?: return
        check(safe.path != rootPath) { "Refusing to delete photo cache root" }
        safe.listFiles().orEmpty().forEach { child ->
            val checked = try {
                internalFile(child.path)
            } catch (_: IllegalStateException) {
                null
            } ?: return@forEach
            if (checked.isDirectory) deleteInternalTree(checked) else checked.delete()
        }
        safe.delete()
    }

    private fun expireStaleBatch(nowMillis: Long = System.currentTimeMillis()) {
        val active = batch ?: return
        if (nowMillis - active.updatedAt <= RETENTION_MILLIS) return
        val complete = active.slots.values.all { it.finalFile?.isFile == true }
        closeBatch(deleteFiles = !complete)
        stateFile.delete()
        if (!complete) ReceiverRuntime.update { it.copy(photoPaths = emptyList(), photoSlots = emptyList()) }
        cleanupCompletedBatches()
    }

    private fun cleanupExpiredParts(nowMillis: Long = System.currentTimeMillis()) {
        safeBatchDirectories().forEach { directory ->
            safeDescendants(directory)
                .filter { it.isFile && it.extension == "part" && nowMillis - it.lastModified() > RETENTION_MILLIS }
                .forEach(::deleteInternalFile)
            if (directory.listFiles().isNullOrEmpty()) directory.delete()
        }
    }

    private fun cleanupCompletedBatches() {
        val protectedId = batch?.batchId
        val directories = safeBatchDirectories()
            .filter { directory ->
                directory.name != protectedId &&
                    safeDescendants(directory).none { it.isFile && it.extension == "part" }
            }
            .sortedByDescending(File::lastModified)
        var retainedBytes = batch?.slots?.values?.sumOf { it.finalFile?.length() ?: it.file?.length() ?: 0L } ?: 0L
        directories.forEachIndexed { index, directory ->
            val size = safeDescendants(directory).filter(File::isFile).sumOf(File::length)
            if (index >= MAX_COMPLETED_BATCHES || retainedBytes + size > MAX_BATCH_BYTES) {
                deleteInternalTree(directory)
            } else {
                retainedBytes += size
            }
        }
    }

    private fun safeBatchDirectories(): List<File> = root.listFiles().orEmpty().mapNotNull { candidate ->
        if (!candidate.isDirectory || !isUuid(candidate.name)) return@mapNotNull null
        try {
            internalFile(candidate.path, root)
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun safeDescendants(directory: File): Sequence<File> = directory.walkTopDown().mapNotNull { candidate ->
        try {
            internalFile(candidate.path)
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun isUuid(value: String): Boolean = UUID_PATTERN.matches(value)

    private fun addTombstone(transferId: String) {
        tombstones.remove(transferId)
        while (tombstones.size >= MAX_TOMBSTONES) {
            tombstones.remove(tombstones.entries.first().key)
        }
        tombstones[transferId] = Tombstone(System.currentTimeMillis())
    }

    private fun cleanupTombstones(nowMillis: Long = System.currentTimeMillis()) {
        val expired = tombstones
            .filterValues { nowMillis - it.createdAt > TOMBSTONE_RETENTION_MILLIS }
            .keys
            .toList()
        expired.forEach(tombstones::remove)
    }

    private fun recordUnknownFrame(nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (unknownWindowStartedAt == 0L || nowMillis - unknownWindowStartedAt > UNKNOWN_WINDOW_MILLIS) {
            unknownWindowStartedAt = nowMillis
            unknownFrameCount = 0
        }
        unknownFrameCount += 1
        return unknownFrameCount > MAX_UNKNOWN_FRAMES
    }

    private fun JsonObject.string(name: String): String = this[name]?.jsonPrimitive?.contentOrNull
        ?: throw IllegalArgumentException("Missing $name")
    private fun JsonObject.long(name: String): Long = this[name]?.jsonPrimitive?.longOrNull
        ?: throw IllegalArgumentException("Missing $name")
    private fun JsonObject.int(name: String): Int = this[name]?.jsonPrimitive?.intOrNull
        ?: throw IllegalArgumentException("Missing $name")
    private fun ok() = buildJsonObject { put("ok", true) }
    private fun errorResult(type: String, code: String, message: String) = PhotoCommandResult(type, buildJsonObject {
        put("ok", false); put("error", buildJsonObject { put("code", code); put("message", message) })
    })

    private companion object {
        const val MAX_PAYLOAD = PhotoChunkCodec.MAX_PAYLOAD_SIZE
        const val ACK_WINDOW = 32
        const val ACK_INTERVAL_MILLIS = 250L
        const val MAX_BATCH_BYTES = 512L * 1_024L * 1_024L
        const val MAX_CHUNKS = 8_192
        const val STORAGE_RESERVE = 1L * 1_024L * 1_024L * 1_024L
        const val RETENTION_MILLIS = 10L * 60L * 1_000L
        const val MAX_COMPLETED_BATCHES = 5
        const val MAX_DUPLICATE_FRAMES = 32
        const val DUPLICATE_WINDOW_MILLIS = 10_000L
        const val MAX_TOMBSTONES = 256
        const val MAX_TOMBSTONE_FRAMES = 32
        const val TOMBSTONE_RETENTION_MILLIS = 60_000L
        const val MAX_UNKNOWN_FRAMES = 32
        const val UNKNOWN_WINDOW_MILLIS = 10_000L
        val UUID_PATTERN = Regex(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
        )
    }

    private val stateFile: File
        get() = File(root, "active_batch.json")
}
