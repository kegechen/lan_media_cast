package com.iflytek.lanmediacast.receiver.playback

data class PlaylistRestoreDecision(
    val index: Int,
    val positionMs: Long,
)

fun choosePlaylistRestore(
    itemIds: List<String>,
    currentItemId: String?,
    currentPositionMs: Long,
    requestedItemId: String?,
): PlaylistRestoreDecision {
    val currentIndex = currentItemId?.let(itemIds::indexOf) ?: -1
    if (currentIndex >= 0) {
        return PlaylistRestoreDecision(currentIndex, currentPositionMs.coerceAtLeast(0L))
    }
    val requestedIndex = requestedItemId?.let(itemIds::indexOf) ?: -1
    return PlaylistRestoreDecision(requestedIndex.coerceAtLeast(0), 0L)
}
