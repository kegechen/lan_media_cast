package com.iflytek.lanmediacast.receiver.playback

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Base64
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.BufferedReader
import java.io.Closeable
import java.io.IOException
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@UnstableApi
@RunWith(AndroidJUnit4::class)
class SplitMediaSourcePlaybackTest {
    @Test
    fun splitHttpTracksPlayThroughTheProductionSourceFactory() {
        val video = Base64.decode(VALID_VIDEO_MP4_BASE64, Base64.DEFAULT)
        val audio = createWaveAudio()
        val server = ByteHttpServer(
            mapOf(
                "/video.mp4" to HttpResource("video/mp4", video),
                "/audio.wav" to HttpResource("audio/wav", audio),
            ),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val result = CountDownLatch(1)
        val hasVideo = AtomicBoolean(false)
        val hasAudio = AtomicBoolean(false)
        val stateReady = AtomicBoolean(false)
        val frameRendered = AtomicBoolean(false)
        val firstPlaybackPosition = AtomicLong(0L)
        val playbackPosition = AtomicLong(0L)
        val failure = AtomicReference<PlaybackException?>()
        var player: ExoPlayer? = null
        var coordinator: PlaybackCoordinator? = null
        var surfaceTexture: SurfaceTexture? = null
        var videoSurface: Surface? = null
        fun signalWhenReady() {
            if (hasVideo.get() && hasAudio.get() && stateReady.get() && frameRendered.get()) {
                result.countDown()
            }
        }
        try {
            instrumentation.runOnMainSync {
                val createdCoordinator = PlaybackCoordinator(context) {}
                coordinator = createdCoordinator
                val createdPlayer = ExoPlayer.Builder(context).build()
                player = createdPlayer
                createdPlayer.volume = 0f
                val createdTexture = SurfaceTexture(false).apply { setDefaultBufferSize(160, 90) }
                val createdSurface = Surface(createdTexture)
                surfaceTexture = createdTexture
                videoSurface = createdSurface
                createdPlayer.setVideoSurface(createdSurface)
                createdPlayer.addListener(object : Player.Listener {
                    override fun onTracksChanged(tracks: Tracks) {
                        hasVideo.set(tracks.hasSelectedSupportedTrack(C.TRACK_TYPE_VIDEO))
                        hasAudio.set(tracks.hasSelectedSupportedTrack(C.TRACK_TYPE_AUDIO))
                        signalWhenReady()
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY) stateReady.set(true)
                        signalWhenReady()
                    }

                    override fun onRenderedFirstFrame() {
                        frameRendered.set(true)
                        signalWhenReady()
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        failure.set(error)
                        result.countDown()
                    }
                })
                val source = buildJsonObject {
                    put("kind", "url")
                    put("name", "Split playback test")
                    put("url", server.url("/video.mp4"))
                    put("cacheKey", "split-video-${System.nanoTime()}")
                    put("httpHeaders", buildJsonObject { put("User-Agent", "video-track-agent") })
                    put("audioTrack", buildJsonObject {
                        put("url", server.url("/audio.wav"))
                        put("cacheKey", "split-audio-${System.nanoTime()}")
                        put("httpHeaders", buildJsonObject { put("User-Agent", "audio-track-agent") })
                    })
                }
                createdPlayer.setMediaSource(createdCoordinator.createRemoteMediaSourceForTesting(source))
                createdPlayer.playWhenReady = true
                createdPlayer.prepare()
            }

            val completed = result.await(15, TimeUnit.SECONDS)
            if (completed) {
                for (attempt in 0 until 20) {
                    Thread.sleep(50)
                    instrumentation.runOnMainSync {
                        playbackPosition.set(player?.currentPosition ?: 0L)
                    }
                    if (playbackPosition.get() > 0L) {
                        firstPlaybackPosition.set(playbackPosition.get())
                        break
                    }
                }
                for (attempt in 0 until 20) {
                    Thread.sleep(50)
                    instrumentation.runOnMainSync {
                        playbackPosition.set(player?.currentPosition ?: 0L)
                    }
                    if (playbackPosition.get() > firstPlaybackPosition.get()) break
                }
            }
            assertNull("test HTTP server failed: ${server.failure?.message}", server.failure)
            assertTrue("split media did not become ready", completed)
            assertNull(
                "split media failed: ${failure.get()?.message}; requests=${server.requests}",
                failure.get(),
            )
            assertTrue("video track was not selected and supported", hasVideo.get())
            assertTrue("audio track was not selected and supported", hasAudio.get())
            assertTrue("first video frame was not rendered", frameRendered.get())
            assertTrue(
                "split playback position did not advance",
                firstPlaybackPosition.get() > 0L && playbackPosition.get() > firstPlaybackPosition.get(),
            )
            assertTrue(
                "primary request headers leaked or were missing: ${server.requests}",
                server.requests.any { it.path == "/video.mp4" && it.userAgent == "video-track-agent" } &&
                    server.requests.none { it.path == "/video.mp4" && it.userAgent == "audio-track-agent" },
            )
            assertTrue(
                "audio request headers leaked or were missing: ${server.requests}",
                server.requests.any { it.path == "/audio.wav" && it.userAgent == "audio-track-agent" } &&
                    server.requests.none { it.path == "/audio.wav" && it.userAgent == "video-track-agent" },
            )
        } finally {
            instrumentation.runOnMainSync {
                player?.clearVideoSurface()
                player?.release()
                videoSurface?.release()
                surfaceTexture?.release()
                coordinator?.close()
            }
            instrumentation.waitForIdleSync()
            server.close()
        }
    }

    private fun Tracks.hasSelectedSupportedTrack(type: Int): Boolean = groups.any { group ->
        group.type == type && (0 until group.length).any { index ->
            group.isTrackSelected(index) && group.isTrackSupported(index)
        }
    }

    private fun createWaveAudio(): ByteArray {
        val sampleRate = 8_000
        val sampleCount = sampleRate
        val pcmLength = sampleCount * 2
        val buffer = ByteBuffer.allocate(44 + pcmLength).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray())
        buffer.putInt(36 + pcmLength)
        buffer.put("WAVEfmt ".toByteArray())
        buffer.putInt(16)
        buffer.putShort(1)
        buffer.putShort(1)
        buffer.putInt(sampleRate)
        buffer.putInt(sampleRate * 2)
        buffer.putShort(2)
        buffer.putShort(16)
        buffer.put("data".toByteArray())
        buffer.putInt(pcmLength)
        repeat(sampleCount) { index ->
            val sample = (sin(2.0 * PI * 440.0 * index / sampleRate) * Short.MAX_VALUE * 0.2).toInt()
            buffer.putShort(sample.toShort())
        }
        return buffer.array()
    }

    private companion object {
        const val VALID_VIDEO_MP4_BASE64 =
            "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"
    }
}

private data class HttpResource(val contentType: String, val bytes: ByteArray)
private data class HttpRequestRecord(val path: String?, val range: String?, val userAgent: String?)

private class ByteHttpServer(private val resources: Map<String, HttpResource>) : Closeable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val serverFailure = AtomicReference<Throwable?>()
    val requests = CopyOnWriteArrayList<HttpRequestRecord>()

    val failure: Throwable?
        get() = serverFailure.get()

    init {
        executor.execute {
            while (!server.isClosed) {
                try {
                    val socket = server.accept()
                    executor.execute {
                        try {
                            socket.use(::serve)
                        } catch (error: Throwable) {
                            serverFailure.compareAndSet(null, error)
                        }
                    }
                } catch (error: IOException) {
                    if (!server.isClosed) serverFailure.compareAndSet(null, error)
                    break
                }
            }
        }
    }

    fun url(path: String): String = "http://127.0.0.1:${server.localPort}$path"

    private fun serve(socket: java.net.Socket) {
        socket.soTimeout = 5_000
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII))
        val requestLine = reader.readLine() ?: return
        val requestHeaders = mutableMapOf<String, String>()
        var header = reader.readLine()
        while (!header.isNullOrEmpty()) {
            val separator = header.indexOf(':')
            if (separator > 0) {
                requestHeaders[header.substring(0, separator).trim().lowercase()] =
                    header.substring(separator + 1).trim()
            }
            header = reader.readLine()
        }
        val path = requestLine.split(' ').getOrNull(1)
        requests += HttpRequestRecord(path, requestHeaders["range"], requestHeaders["user-agent"])
        val resource = resources[path]
        if (resource == null) {
            writeResponse(
                socket,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                ByteArray(0),
            )
            return
        }
        val range = requestHeaders["range"]?.let { value ->
            Regex("bytes=(\\d+)-(\\d*)").matchEntire(value)?.let { match ->
                val start = match.groupValues[1].toLong()
                val requestedEnd = match.groupValues[2].toLongOrNull() ?: (resource.bytes.size.toLong() - 1L)
                start..requestedEnd.coerceAtMost(resource.bytes.size.toLong() - 1L)
            }
        }
        if (range != null && (range.first >= resource.bytes.size || range.last < range.first)) {
            writeResponse(
                socket,
                "HTTP/1.1 416 Range Not Satisfiable\r\n" +
                    "Content-Range: bytes */${resource.bytes.size}\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n",
                ByteArray(0),
            )
            return
        }
        val responseBytes = range?.let {
            resource.bytes.copyOfRange(it.first.toInt(), it.last.toInt() + 1)
        } ?: resource.bytes
        val status = if (range == null) "200 OK" else "206 Partial Content"
        val headers = "HTTP/1.1 $status\r\n" +
            "Content-Type: ${resource.contentType}\r\n" +
            "Content-Length: ${responseBytes.size}\r\n" +
            (range?.let { "Content-Range: bytes ${it.first}-${it.last}/${resource.bytes.size}\r\n" } ?: "") +
            "Accept-Ranges: bytes\r\n" +
            "Connection: close\r\n\r\n"
        writeResponse(socket, headers, responseBytes)
    }

    private fun writeResponse(socket: java.net.Socket, headers: String, body: ByteArray) {
        try {
            val output = socket.getOutputStream()
            output.write(headers.toByteArray(StandardCharsets.US_ASCII))
            output.write(body)
            output.flush()
        } catch (_: IOException) {
            // ExoPlayer may close a fully parsed source before consuming the tiny response body.
        }
    }

    override fun close() {
        server.close()
        executor.shutdownNow()
        executor.awaitTermination(5, TimeUnit.SECONDS)
    }
}
