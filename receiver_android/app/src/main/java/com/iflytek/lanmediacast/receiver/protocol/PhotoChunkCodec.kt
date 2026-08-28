package com.iflytek.lanmediacast.receiver.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

data class PhotoChunkFrame(
    val transferId: UUID,
    val chunkIndex: Long,
    val isLast: Boolean,
    val payload: ByteArray,
)

object PhotoChunkCodec {
    const val HEADER_SIZE = 32
    const val MAX_PAYLOAD_SIZE = 64 * 1_024

    private val magic = byteArrayOf('L'.code.toByte(), 'M'.code.toByte(), 'C'.code.toByte(), '1'.code.toByte())

    fun encode(frame: PhotoChunkFrame): ByteArray {
        require(frame.chunkIndex in 0..0xffff_ffffL) { "chunkIndex is outside uint32" }
        require(frame.payload.size <= MAX_PAYLOAD_SIZE) { "Photo chunk payload is too large" }
        return ByteBuffer.allocate(HEADER_SIZE + frame.payload.size).order(ByteOrder.BIG_ENDIAN).apply {
            put(magic)
            put(1)
            put(0x10)
            putShort(if (frame.isLast) 1 else 0)
            putLong(frame.transferId.mostSignificantBits)
            putLong(frame.transferId.leastSignificantBits)
            putInt(frame.chunkIndex.toInt())
            putInt(frame.payload.size)
            put(frame.payload)
        }.array()
    }

    fun decode(bytes: ByteArray): PhotoChunkFrame {
        require(bytes.size >= HEADER_SIZE) { "Photo chunk header is truncated" }
        val header = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val actualMagic = ByteArray(4).also(header::get)
        val version = header.get().toInt() and 0xff
        val kind = header.get().toInt() and 0xff
        val flags = header.short.toInt() and 0xffff
        require(actualMagic.contentEquals(magic) && version == 1 && kind == 0x10) {
            "Photo chunk signature is invalid"
        }
        require(flags and 0xfffe == 0) { "Photo chunk flags are invalid" }
        val transferId = UUID(header.long, header.long)
        val chunkIndex = header.int.toLong() and 0xffff_ffffL
        val payloadLength = header.int
        require(payloadLength in 0..MAX_PAYLOAD_SIZE && bytes.size == HEADER_SIZE + payloadLength) {
            "Photo chunk length is invalid"
        }
        return PhotoChunkFrame(
            transferId = transferId,
            chunkIndex = chunkIndex,
            isLast = flags == 1,
            payload = bytes.copyOfRange(HEADER_SIZE, bytes.size),
        )
    }
}
