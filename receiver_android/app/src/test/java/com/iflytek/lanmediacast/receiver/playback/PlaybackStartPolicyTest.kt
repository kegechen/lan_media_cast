package com.iflytek.lanmediacast.receiver.playback

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackStartPolicyTest {
    @Test
    fun `play prepares stopped player when media remains loaded`() {
        assertTrue(shouldPrepareForPlay(Player.STATE_IDLE, mediaItemCount = 1))
    }

    @Test
    fun `play does not prepare an empty or already prepared player`() {
        assertFalse(shouldPrepareForPlay(Player.STATE_IDLE, mediaItemCount = 0))
        assertFalse(shouldPrepareForPlay(Player.STATE_READY, mediaItemCount = 1))
    }
}
