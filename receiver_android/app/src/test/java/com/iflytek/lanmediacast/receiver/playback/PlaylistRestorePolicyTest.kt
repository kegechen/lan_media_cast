package com.iflytek.lanmediacast.receiver.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistRestorePolicyTest {
    @Test
    fun `playlist replacement preserves the active item and position`() {
        val decision = choosePlaylistRestore(
            itemIds = listOf("next", "active", "last"),
            currentItemId = "active",
            currentPositionMs = 42_500L,
            requestedItemId = "next",
        )

        assertEquals(1, decision.index)
        assertEquals(42_500L, decision.positionMs)
    }

    @Test
    fun `removed active item falls back to requested item at the start`() {
        val decision = choosePlaylistRestore(
            itemIds = listOf("first", "requested"),
            currentItemId = "removed",
            currentPositionMs = 42_500L,
            requestedItemId = "requested",
        )

        assertEquals(1, decision.index)
        assertEquals(0L, decision.positionMs)
    }
}
