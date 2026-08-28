package com.iflytek.lanmediacast.receiver.playback

import com.iflytek.lanmediacast.receiver.core.ReceiverUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class PlaybackBannerStateTest {
    @Test
    fun `ready playback clears stale playback and buffering banners`() {
        val recovered = clearTransientPlaybackBannerOnReady(
            ReceiverUiState(
                banner = "播放失败：ERROR_CODE_IO_BAD_HTTP_STATUS",
                bannerIsError = true,
            ),
        )
        val resumed = clearTransientPlaybackBannerOnReady(
            ReceiverUiState(banner = "网络不稳定，正在播放缓存或等待数据"),
        )

        assertNull(recovered.banner)
        assertFalse(recovered.bannerIsError)
        assertNull(resumed.banner)
    }

    @Test
    fun `ready playback preserves unrelated connection banners`() {
        val state = ReceiverUiState(
            banner = "发送端连接已断开，缓存播放不受影响",
            bannerIsError = true,
        )

        assertSame(state, clearTransientPlaybackBannerOnReady(state))
    }

    @Test
    fun `http playback failures have actionable messages`() {
        assertEquals(
            "播放地址已失效或媒体服务器拒绝访问（HTTP 403），请在发送端重新解析",
            playbackFailureBanner("ERROR_CODE_IO_BAD_HTTP_STATUS", 403),
        )
        assertEquals(
            "播放失败：ERROR_CODE_DECODING_FAILED",
            playbackFailureBanner("ERROR_CODE_DECODING_FAILED", null),
        )
    }
}
