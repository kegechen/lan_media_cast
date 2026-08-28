package com.iflytek.lanmediacast.receiver.security

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

object SasCalculator {
    fun calculate(
        certificateDigest: ByteArray,
        senderId: String,
        senderNonce: ByteArray,
        receiverNonce: ByteArray,
        challengeId: String,
    ): String {
        require(certificateDigest.size == 32)
        require(senderNonce.size == 32)
        require(receiverNonce.size == 32)
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("LMC1-SAS".toByteArray(Charsets.US_ASCII))
        digest.update(certificateDigest)
        digest.update(uuidBytes(senderId))
        digest.update(senderNonce)
        digest.update(receiverNonce)
        digest.update(uuidBytes(challengeId))
        val hash = digest.digest()
        val value = ByteBuffer.wrap(hash, 0, 4).int.toLong() and 0xffff_ffffL
        return (value % 1_000_000L).toString().padStart(6, '0')
    }

    private fun uuidBytes(value: String): ByteArray {
        val uuid = UUID.fromString(value)
        return ByteBuffer.allocate(16)
            .putLong(uuid.mostSignificantBits)
            .putLong(uuid.leastSignificantBits)
            .array()
    }
}
