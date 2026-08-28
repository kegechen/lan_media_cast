package com.iflytek.lanmediacast.receiver.playback

import androidx.media3.common.C

internal fun castHttpRetryDelay(
    responseCode: Int,
    errorCount: Int,
    retryAfterSeconds: Long? = null,
): Long {
    if (responseCode == 503) {
        return retryAfterSeconds?.coerceIn(1L, 30L)?.times(1_000L)
            ?: castTransientRetryDelay(errorCount)
    }
    return castPermanentRetryDelay(errorCount)
}

internal fun castTransientRetryDelay(errorCount: Int): Long {
    val exponent = (errorCount - 1).coerceIn(0, 5)
    return (500L * (1L shl exponent)).coerceAtMost(10_000L)
}

internal fun castPermanentRetryDelay(errorCount: Int): Long = when (errorCount) {
    1 -> 1_000L
    2 -> 2_000L
    3 -> 4_000L
    else -> C.TIME_UNSET
}
