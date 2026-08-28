package com.iflytek.lanmediacast.receiver.core

import androidx.media3.common.Player
import java.util.concurrent.CopyOnWriteArrayList

data class PairingRequest(
    val senderName: String,
    val code: String,
)

data class PhotoSlotUiState(
    val photoId: String,
    val path: String? = null,
)

data class ReceiverUiState(
    val deviceName: String = "LAN Media Cast",
    val address: String = "正在获取网络地址",
    val controlPort: Int = 39881,
    val connectedSender: String? = null,
    val banner: String? = null,
    val bannerIsError: Boolean = false,
    val pairingRequest: PairingRequest? = null,
    val mode: String = "media",
    val playbackStopped: Boolean = false,
    val photoPaths: List<String> = emptyList(),
    val photoSlots: List<PhotoSlotUiState> = emptyList(),
)

internal enum class ReceiverStandbyMode {
    HIDDEN,
    WAITING_FOR_CONNECTION,
    READY_FOR_MEDIA,
}

internal fun receiverStandbyMode(state: ReceiverUiState, hasLoadedMedia: Boolean): ReceiverStandbyMode {
    if (state.mode != "media" || state.photoSlots.isNotEmpty() || state.photoPaths.isNotEmpty()) {
        return ReceiverStandbyMode.HIDDEN
    }
    if (state.connectedSender == null) {
        return if (!hasLoadedMedia || state.playbackStopped) {
            ReceiverStandbyMode.WAITING_FOR_CONNECTION
        } else {
            ReceiverStandbyMode.HIDDEN
        }
    }
    return if (!hasLoadedMedia || state.playbackStopped) {
        ReceiverStandbyMode.READY_FOR_MEDIA
    } else {
        ReceiverStandbyMode.HIDDEN
    }
}

object ReceiverRuntime {
    private val listeners = CopyOnWriteArrayList<(ReceiverUiState) -> Unit>()

    @Volatile
    var player: Player? = null
        private set

    @Volatile
    var state: ReceiverUiState = ReceiverUiState()
        private set

    fun attachPlayer(value: Player?) {
        player = value
        notifyListeners(state)
    }

    fun update(transform: (ReceiverUiState) -> ReceiverUiState) {
        val snapshot = synchronized(this) {
            transform(state).also { state = it }
        }
        notifyListeners(snapshot)
    }

    fun addListener(listener: (ReceiverUiState) -> Unit) {
        listeners += listener
        listener(state)
    }

    fun removeListener(listener: (ReceiverUiState) -> Unit) {
        listeners -= listener
    }

    private fun notifyListeners(snapshot: ReceiverUiState) {
        listeners.forEach { it(snapshot) }
    }
}
