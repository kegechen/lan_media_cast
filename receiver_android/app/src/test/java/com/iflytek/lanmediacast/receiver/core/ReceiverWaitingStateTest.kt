package com.iflytek.lanmediacast.receiver.core

import org.junit.Assert.assertEquals
import org.junit.Test

class ReceiverWaitingStateTest {
    @Test
    fun `idle disconnected receiver waits for connection`() {
        assertEquals(
            ReceiverStandbyMode.WAITING_FOR_CONNECTION,
            receiverStandbyMode(ReceiverUiState(), hasLoadedMedia = false),
        )
    }

    @Test
    fun `cached media remains visible after control disconnects`() {
        assertEquals(
            ReceiverStandbyMode.HIDDEN,
            receiverStandbyMode(ReceiverUiState(), hasLoadedMedia = true),
        )
    }

    @Test
    fun `connected receiver without media is ready for media`() {
        assertEquals(
            ReceiverStandbyMode.READY_FOR_MEDIA,
            receiverStandbyMode(
                ReceiverUiState(connectedSender = "Teacher PC"),
                hasLoadedMedia = false,
            ),
        )
    }

    @Test
    fun `stopped playback returns connected receiver to ready screen`() {
        assertEquals(
            ReceiverStandbyMode.READY_FOR_MEDIA,
            receiverStandbyMode(
                ReceiverUiState(connectedSender = "Teacher PC", playbackStopped = true),
                hasLoadedMedia = true,
            ),
        )
    }

    @Test
    fun `paused playback remains visible`() {
        assertEquals(
            ReceiverStandbyMode.HIDDEN,
            receiverStandbyMode(
                ReceiverUiState(connectedSender = "Teacher PC", playbackStopped = false),
                hasLoadedMedia = true,
            ),
        )
    }

    @Test
    fun `photo mode suppresses media standby screen`() {
        assertEquals(
            ReceiverStandbyMode.HIDDEN,
            receiverStandbyMode(
                ReceiverUiState(photoSlots = listOf(PhotoSlotUiState("photo-1"))),
                hasLoadedMedia = false,
            ),
        )
    }
}
