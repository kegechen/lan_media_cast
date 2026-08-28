package com.iflytek.lanmediacast.receiver.network

import java.security.MessageDigest

internal enum class PairingDecision {
    ACCEPTED,
    INCORRECT_CODE,
    INVALID_CHALLENGE,
    EXPIRED,
    ALREADY_CONSUMED,
}

internal class PairingChallenge(
    val id: String,
    val code: String,
    val expiresAt: Long,
) {
    private var consumed = false

    @Synchronized
    fun verify(challengeId: String?, submittedCode: String?, nowMillis: Long): PairingDecision {
        if (consumed) return PairingDecision.ALREADY_CONSUMED
        if (nowMillis > expiresAt) {
            consumed = true
            return PairingDecision.EXPIRED
        }
        if (challengeId != id) return PairingDecision.INVALID_CHALLENGE
        val matches = submittedCode != null && PairingCode.isValid(submittedCode) && MessageDigest.isEqual(
            code.toByteArray(Charsets.US_ASCII),
            submittedCode.toByteArray(Charsets.US_ASCII),
        )
        if (!matches) return PairingDecision.INCORRECT_CODE
        consumed = true
        return PairingDecision.ACCEPTED
    }

    @Synchronized
    fun expireIfNeeded(nowMillis: Long): Boolean {
        if (consumed || nowMillis <= expiresAt) return false
        consumed = true
        return true
    }
}
