package com.iflytek.lanmediacast.receiver.playback

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import androidx.annotation.VisibleForTesting
import androidx.media3.common.MediaItem
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSink
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.core.ReceiverLog
import com.iflytek.lanmediacast.receiver.core.ReceiverUiState
import com.iflytek.lanmediacast.receiver.protocol.RemoteMediaSourceValidator
import com.iflytek.lanmediacast.receiver.protocol.RemoteMediaTrack
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.X509TrustManager
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Interceptor
import okhttp3.Response

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class PlaybackCoordinator(
    private val context: Context,
    private val emitState: (JsonObject) -> Unit,
) : AutoCloseable {
    private data class Endpoint(
        val peerAddress: String,
        val port: Int,
        val generation: Long,
        val certificatePin: ByteArray,
        val token: String,
    )

    private data class CastItem(
        val id: String,
        val name: String,
        val source: JsonObject,
        val httpHeaders: Map<String, String>,
        val audioTrack: RemoteMediaTrack?,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val databaseProvider = StandaloneDatabaseProvider(context)
    private val cacheDirectory = File(context.cacheDir, "media_cache")
    private val cacheQuota = calculateCacheQuota(cacheDirectory)
    private val cache = SimpleCache(cacheDirectory, LeastRecentlyUsedCacheEvictor(cacheQuota), databaseProvider)
    private val cacheWritePolicy = CacheWritePolicy(
        initialEnabled = availableCacheCapacity() >= MIN_CACHE_BYTES,
    )
    private val cacheSinkFactory = ConditionalCacheDataSinkFactory(
        CacheDataSink.Factory().setCache(cache),
        ::shouldWriteCache,
    )
    private val player = ExoPlayer.Builder(context).build()
    private val loadErrorPolicy = CastLoadErrorPolicy()
    private val remoteHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()
    @Volatile
    private var items: List<CastItem> = emptyList()

    @Volatile
    private var endpoint: Endpoint? = null

    @Volatile
    private var endpointClient: OkHttpClient? = null

    @Volatile
    private var endpointClientPin: ByteArray? = null

    @Volatile
    private var playlistRevision = 0L

    @Volatile
    private var lastPlaylistPayload: JsonObject? = null

    private val stateSequence = AtomicLong()

    @Volatile
    private var repeatMode = "playOnce"

    @Volatile
    private var muted = false

    @Volatile
    private var unmutedVolume = 1f
    private var resumeAfterPhoto = false
    private val positionPublisher = object : Runnable {
        override fun run() {
            if (player.isPlaying) publishState()
            mainHandler.postDelayed(this, POSITION_UPDATE_MILLIS)
        }
    }

    init {
        ReceiverRuntime.attachPlayer(player)
        player.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) = publishState()

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_BUFFERING && player.currentPosition > 0L) {
                    ReceiverRuntime.update {
                        if (it.connectedSender == null) it else it.copy(
                            banner = "网络不稳定，正在播放缓存或等待数据",
                            bannerIsError = false,
                        )
                    }
                } else if (playbackState == Player.STATE_READY) {
                    ReceiverRuntime.update(::clearTransientPlaybackBannerOnReady)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                ReceiverLog.e(
                    TAG,
                    "Playback failed: code=${error.errorCodeName}, causes=${playbackErrorCauses(error)}",
                )
                ReceiverRuntime.update {
                    it.copy(
                        banner = playbackFailureBanner(
                            error.errorCodeName,
                            playbackHttpResponseCode(error),
                        ),
                        bannerIsError = true,
                    )
                }
                publishState(error.errorCodeName)
            }

            override fun onTracksChanged(tracks: Tracks) {
                ReceiverLog.i(TAG, "Tracks changed: ${trackSummary(tracks)}")
            }
        })
        mainHandler.post(positionPublisher)
    }

    fun announceEndpoint(peerAddress: String, payload: JsonObject): JsonObject {
        val scheme = payload.string("scheme")
        if (scheme != "https") return error("invalid_message", "Only HTTPS endpoints are accepted")
        val generation = payload.long("generation")
        val current = endpoint
        if (current != null && generation <= current.generation) {
            return error("stale_generation", "Endpoint generation is not newer")
        }
        val port = payload.int("port")
        if (port !in 1..65_535) return error("invalid_message", "Invalid endpoint port")
        val pin = decodeBase64Url(payload.string("certificateSha256"))
        if (pin.size != 32) return error("invalid_message", "Certificate pin must be 32 bytes")
        val token = payload.string("bearerToken")
        if (decodeBase64Url(token).size != 32) return error("invalid_message", "Bearer token must be 32 bytes")
        endpoint = Endpoint(peerAddress, port, generation, pin, token)
        val currentClient = endpointClient
        val currentClientPin = endpointClientPin
        if (currentClient == null || currentClientPin == null || !MessageDigest.isEqual(currentClientPin, pin)) {
            endpointClient = pinnedClient(pin)
            endpointClientPin = pin.copyOf()
            if (currentClient != null) retireClient(currentClient)
        }
        val currentItems = items
        if (currentItems.any { it.source["kind"]?.jsonPrimitive?.contentOrNull == "local" }) {
            reloadSourcesPreservingPlayback()
        }
        return ok()
    }

    fun replacePlaylist(payload: JsonObject): JsonObject {
        val revision = payload.long("revision")
        if (revision < playlistRevision ||
            (revision == playlistRevision && payload != lastPlaylistPayload)) {
            return error("revision_conflict", "Revision conflicts with the current playlist")
        }
        if (revision == playlistRevision) return ok()
        val rawItems = payload["items"] as? JsonArray ?: return error("invalid_message", "items must be an array")
        if (rawItems.size > 500) return error("message_too_large", "Playlist exceeds 500 items")
        val parsed = try {
            rawItems.map { element ->
                val item = element.jsonObject
                val source = item["source"]?.jsonObject ?: error("source missing")
                val name = source["name"]?.jsonPrimitive?.contentOrNull ?: "未命名媒体"
                val kind = source.string("kind")
                require(kind == "local" || kind == "url") { "Unknown media source kind" }
                val remoteSource = if (kind == "url") {
                    RemoteMediaSourceValidator.validate(source)
                } else {
                    require(!source.containsKey("httpHeaders")) { "local source cannot contain httpHeaders" }
                    null
                }
                CastItem(
                    item.string("id"),
                    name,
                    source,
                    remoteSource?.primaryTrack?.httpHeaders.orEmpty(),
                    remoteSource?.audioTrack,
                )
            }
        } catch (failure: Exception) {
            return error("invalid_message", failure.message ?: "Invalid playlist")
        }
        items = parsed
        ReceiverLog.i(
            TAG,
            "Playlist accepted: items=${parsed.size}, splitAudio=${parsed.count { it.audioTrack != null }}",
        )
        playlistRevision = revision
        lastPlaylistPayload = payload
        setRepeatMode(payload["repeatMode"]?.jsonPrimitive?.contentOrNull ?: "playOnce")
        val activeItemId = payload["activeItemId"]?.jsonPrimitive?.contentOrNull
        rebuildSources(activeItemId)
        return ok()
    }

    fun execute(type: String, payload: JsonObject): JsonObject {
        when (type) {
            "player.play" -> mainHandler.post {
                if (shouldPrepareForPlay(player.playbackState, player.mediaItemCount)) player.prepare()
                ReceiverRuntime.update { it.copy(playbackStopped = false) }
                player.play()
            }
            "player.pause" -> mainHandler.post { player.pause() }
            "player.stop" -> mainHandler.post {
                player.stop()
                if (player.mediaItemCount > 0) {
                    val currentIndex = player.currentMediaItemIndex.coerceIn(0, player.mediaItemCount - 1)
                    player.seekToDefaultPosition(currentIndex)
                }
                ReceiverRuntime.update { it.copy(playbackStopped = true) }
            }
            "player.seek" -> {
                val position = payload["positionMs"]?.jsonPrimitive?.longOrNull
                    ?: return error("invalid_message", "positionMs is required")
                if (position < 0) return error("invalid_message", "positionMs cannot be negative")
                mainHandler.post { player.seekTo(position) }
            }
            "player.select" -> {
                val itemId = payload["itemId"]?.jsonPrimitive?.contentOrNull
                    ?: return error("invalid_message", "itemId is required")
                val index = items.indexOfFirst { it.id == itemId }
                if (index < 0) return error("item_not_found", "Playlist item was not found")
                val autoplay = payload["autoplay"]?.jsonPrimitive?.booleanOrNull ?: false
                mainHandler.post {
                    ReceiverRuntime.update { it.copy(playbackStopped = false) }
                    player.seekToDefaultPosition(index)
                    player.prepare()
                    player.playWhenReady = autoplay
                }
            }
            "player.next" -> mainHandler.post { if (player.hasNextMediaItem()) player.seekToNextMediaItem() }
            "player.previous" -> mainHandler.post {
                if (player.hasPreviousMediaItem()) player.seekToPreviousMediaItem() else player.seekTo(0)
            }
            "player.repeat" -> {
                val mode = payload["mode"]?.jsonPrimitive?.contentOrNull
                    ?: return error("invalid_message", "mode is required")
                if (mode !in setOf("repeatOne", "repeatAll", "playOnce")) {
                    return error("invalid_message", "Unknown repeat mode")
                }
                setRepeatMode(mode)
            }
            "player.volume" -> {
                val value = payload["value"]?.jsonPrimitive?.intOrNull
                    ?: return error("invalid_message", "value is required")
                if (value !in 0..100) return error("invalid_message", "Volume must be 0-100")
                unmutedVolume = value / 100f
                mainHandler.post { if (!muted) player.volume = unmutedVolume }
                return buildJsonObject { put("ok", true); put("value", value) }
            }
            "player.mute" -> {
                val value = payload["muted"]?.jsonPrimitive?.booleanOrNull
                    ?: return error("invalid_message", "muted is required")
                muted = value
                mainHandler.post { player.volume = if (value) 0f else unmutedVolume }
            }
            else -> return error("invalid_message", "Unsupported command")
        }
        return ok()
    }

    fun cacheAvailable(): Boolean = cache.cacheSpace > 0L

    fun beginSession() {
        endpoint = null
        stateSequence.set(0L)
    }

    fun currentPlaylistRevision(): Long = playlistRevision

    fun enterPhotoMode() {
        mainHandler.post {
            resumeAfterPhoto = player.playWhenReady
            player.pause()
        }
    }

    fun exitPhotoMode() {
        mainHandler.post {
            if (resumeAfterPhoto) player.play()
            resumeAfterPhoto = false
        }
    }

    private fun rebuildSources(activeItemId: String?) {
        val currentItems = items
        val sources = try {
            currentItems.map(::createMediaSource)
        } catch (failure: Exception) {
            ReceiverRuntime.update {
                it.copy(banner = "无法载入播放列表：${failure.message}", bannerIsError = true)
            }
            return
        }
        mainHandler.post {
            if (sources.isEmpty()) {
                player.clearMediaItems()
                return@post
            }
            val shouldPlay = player.playWhenReady
            val decision = choosePlaylistRestore(
                itemIds = currentItems.map(CastItem::id),
                currentItemId = player.currentMediaItem?.mediaId,
                currentPositionMs = player.currentPosition,
                requestedItemId = activeItemId,
            )
            player.setMediaSources(sources, decision.index, decision.positionMs)
            player.prepare()
            player.playWhenReady = shouldPlay
        }
    }

    private fun reloadSourcesPreservingPlayback() {
        mainHandler.post {
            val activeItemId = player.currentMediaItem?.mediaId
            val positionMs = player.currentPosition.coerceAtLeast(0L)
            val shouldPlay = player.playWhenReady
            val currentItems = items
            val sources = try {
                currentItems.map(::createMediaSource)
            } catch (failure: Exception) {
                ReceiverRuntime.update {
                    it.copy(banner = "无法恢复媒体端点：${failure.message}", bannerIsError = true)
                }
                return@post
            }
            if (sources.isEmpty()) {
                player.clearMediaItems()
                return@post
            }
            val startIndex = currentItems.indexOfFirst { it.id == activeItemId }.coerceAtLeast(0)
            player.setMediaSources(sources, startIndex, positionMs)
            player.prepare()
            player.playWhenReady = shouldPlay
        }
    }

    private fun createMediaSource(item: CastItem): MediaSource {
        val kind = item.source.string("kind")
        if (kind == "local") {
            val localEndpoint = endpoint ?: throw IllegalStateException("发送端媒体服务尚未公布")
            val path = item.source.string("path")
            require(path.startsWith("/v1/media/") && !path.contains("..")) { "本地媒体路径无效" }
            val contentId = item.source.string("assetContentId")
            val cacheKey = item.source.string("cacheKey")
            val uri = Uri.Builder()
                .scheme("https")
                .encodedAuthority("${localEndpoint.peerAddress}:${localEndpoint.port}")
                .encodedPath(path)
                .build()
            val client = (endpointClient ?: throw IllegalStateException("发送端媒体连接尚未建立"))
                .newBuilder()
                .addInterceptor(EtagPreflightInterceptor("\"$contentId\""))
                .build()
            val headers = mapOf(
                "Authorization" to "Bearer ${localEndpoint.token}",
                "If-Match" to "\"$contentId\"",
            )
            val upstream = OkHttpDataSource.Factory(client).setDefaultRequestProperties(headers)
            val cacheDataSource = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstream)
                .setCacheWriteDataSinkFactory(cacheSinkFactory)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            val mediaItem = MediaItem.Builder()
                .setMediaId(item.id)
                .setUri(uri)
                .setMimeType(item.source["mime"]?.jsonPrimitive?.contentOrNull)
                .setCustomCacheKey(cacheKey)
                .build()
            return ProgressiveMediaSource.Factory(cacheDataSource)
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(mediaItem)
        }

        return createRemoteMediaSource(
            item.id,
            RemoteMediaTrack(item.source, item.httpHeaders),
            item.audioTrack,
        )
    }

    private fun createRemoteMediaSource(
        mediaId: String,
        primaryTrack: RemoteMediaTrack,
        audioTrack: RemoteMediaTrack?,
    ): MediaSource {
        val primary = createRemoteTrackSource(mediaId, primaryTrack.source, primaryTrack.httpHeaders)
        val audio = audioTrack ?: return primary
        ReceiverLog.i(
            TAG,
            "Creating split source: primaryHost=${Uri.parse(primaryTrack.source.string("url")).host}, " +
                "audioHost=${Uri.parse(audio.source.string("url")).host}",
        )
        return mergeRemoteTrackSources(
            primary,
            createRemoteTrackSource("$mediaId:audio", audio.source, audio.httpHeaders),
        )
    }

    @VisibleForTesting
    internal fun createRemoteMediaSourceForTesting(source: JsonObject): MediaSource {
        val validated = RemoteMediaSourceValidator.validate(source)
        return createRemoteMediaSource(
            "split-playback-test",
            validated.primaryTrack,
            validated.audioTrack,
        )
    }

    private fun createRemoteTrackSource(
        mediaId: String,
        source: JsonObject,
        httpHeaders: Map<String, String>,
    ): MediaSource {
        val uri = Uri.parse(source.string("url"))
        val formatHint = source["formatHint"]?.jsonPrimitive?.contentOrNull?.lowercase()
        val mediaItemBuilder = MediaItem.Builder().setMediaId(mediaId).setUri(uri)
        if (formatHint != "hls" && formatHint != "dash") {
            source["cacheKey"]?.jsonPrimitive?.contentOrNull?.let(mediaItemBuilder::setCustomCacheKey)
        }
        val mediaItem = mediaItemBuilder.build()
        if (formatHint == "rtsp") {
            return RtspMediaSource.Factory().createMediaSource(mediaItem)
        }
        val upstream = OkHttpDataSource.Factory(remoteHttpClient)
            .setDefaultRequestProperties(httpHeaders)
        val cacheDataSource = CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            .setCacheWriteDataSinkFactory(cacheSinkFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        return when (formatHint) {
            "hls" -> HlsMediaSource.Factory(cacheDataSource)
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(mediaItem)
            "dash" -> DashMediaSource.Factory(cacheDataSource)
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(mediaItem)
            else -> ProgressiveMediaSource.Factory(cacheDataSource)
                .setLoadErrorHandlingPolicy(loadErrorPolicy)
                .createMediaSource(mediaItem)
        }
    }

    private fun pinnedClient(expectedPin: ByteArray): OkHttpClient {
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
                throw CertificateException("Client certificates are not accepted")

            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val certificate = chain?.firstOrNull() ?: throw CertificateException("Missing server certificate")
                val actual = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
                if (!MessageDigest.isEqual(actual, expectedPin)) throw CertificateException("Certificate pin mismatch")
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val sslContext = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), SecureRandom()) }
        return configureLocalMediaTimeouts(
            OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier { _, session ->
                val certificate = session.peerCertificates.firstOrNull() as? X509Certificate
                val actual = certificate?.let { MessageDigest.getInstance("SHA-256").digest(it.encoded) }
                actual != null && MessageDigest.isEqual(actual, expectedPin)
            }
        ).build()
    }

    private fun retireClient(client: OkHttpClient) {
        mainHandler.postDelayed({
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdown()
        }, CLIENT_RETIRE_DELAY_MILLIS)
    }

    private fun availableCacheCapacity(): Long =
        (cacheDirectory.usableSpace - STORAGE_RESERVE_BYTES).coerceAtLeast(0L)

    private fun shouldWriteCache(): Boolean {
        val wasEnabled = cacheWritePolicy.enabled
        val enabled = cacheWritePolicy.update(availableCacheCapacity(), SystemClock.elapsedRealtime())
        if (wasEnabled != enabled) {
            ReceiverRuntime.update { state ->
                if (enabled) {
                    if (state.banner?.startsWith("存储空间不足") == true) state.copy(banner = null) else state
                } else {
                    state.copy(
                        banner = "存储空间不足，已暂停新缓存；已有缓存耗尽后将等待网络",
                        bannerIsError = false,
                    )
                }
            }
        }
        return enabled
    }

    private fun setRepeatMode(mode: String) {
        repeatMode = mode
        mainHandler.post {
            player.repeatMode = when (mode) {
                "repeatOne" -> Player.REPEAT_MODE_ONE
                "repeatAll" -> Player.REPEAT_MODE_ALL
                else -> Player.REPEAT_MODE_OFF
            }
        }
    }

    private fun publishState(errorCode: String? = null) {
        val sequence = stateSequence.incrementAndGet()
        val currentItems = items
        emitState(buildJsonObject {
            put("sequence", sequence)
            put("playlistRevision", playlistRevision)
            put("itemId", currentItems.getOrNull(player.currentMediaItemIndex)?.id?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
            put("state", playbackStateName())
            put("positionMs", player.currentPosition.coerceAtLeast(0L))
            put("durationMs", player.duration.coerceAtLeast(0L))
            put("bufferedPositionMs", player.bufferedPosition.coerceAtLeast(0L))
            put("volume", (player.volume * 100).toInt())
            put("muted", muted)
            put("repeatMode", repeatMode)
            put("retryAttempt", 0)
            if (errorCode == null) put("error", JsonPrimitive(null as String?)) else put("error", errorCode)
        })
    }

    private fun playbackStateName(): String = when (player.playbackState) {
        Player.STATE_IDLE -> "idle"
        Player.STATE_BUFFERING -> "buffering"
        Player.STATE_READY -> if (player.isPlaying) "playing" else "paused"
        Player.STATE_ENDED -> "completed"
        else -> "error"
    }

    override fun close() {
        ReceiverRuntime.attachPlayer(null)
        mainHandler.removeCallbacks(positionPublisher)
        mainHandler.post {
            player.release()
            endpointClient?.let { client ->
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
            endpointClient = null
            endpointClientPin = null
            remoteHttpClient.connectionPool.evictAll()
            remoteHttpClient.dispatcher.executorService.shutdown()
            cache.release()
            databaseProvider.close()
        }
    }

    private fun JsonObject.string(name: String): String = this[name]?.jsonPrimitive?.contentOrNull
        ?: throw IllegalArgumentException("Missing $name")

    private fun JsonObject.long(name: String): Long = this[name]?.jsonPrimitive?.longOrNull
        ?: throw IllegalArgumentException("Missing $name")

    private fun JsonObject.int(name: String): Int = this[name]?.jsonPrimitive?.intOrNull
        ?: throw IllegalArgumentException("Missing $name")

    private fun decodeBase64Url(value: String): ByteArray = try {
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    } catch (_: IllegalArgumentException) {
        ByteArray(0)
    }

    private fun ok() = buildJsonObject { put("ok", true) }

    private fun error(code: String, message: String) = buildJsonObject {
        put("ok", false)
        put("error", buildJsonObject { put("code", code); put("message", message) })
    }

    private companion object {
        const val TAG = "PlaybackCoordinator"
        const val MIN_CACHE_BYTES = 256L * 1_024L * 1_024L
        const val MAX_CACHE_BYTES = 10L * 1_024L * 1_024L * 1_024L
        const val STORAGE_RESERVE_BYTES = 1L * 1_024L * 1_024L * 1_024L
        const val POSITION_UPDATE_MILLIS = 500L
        const val CLIENT_RETIRE_DELAY_MILLIS = 30_000L

        fun calculateCacheQuota(directory: File): Long {
            directory.mkdirs()
            val allocatable = (directory.usableSpace - STORAGE_RESERVE_BYTES).coerceAtLeast(0L)
            return (directory.usableSpace / 5L).coerceAtMost(MAX_CACHE_BYTES).coerceAtMost(allocatable)
                .coerceAtLeast(MIN_CACHE_BYTES.coerceAtMost(allocatable))
        }
    }
}

@VisibleForTesting
internal fun configureLocalMediaTimeouts(builder: OkHttpClient.Builder): OkHttpClient.Builder =
    builder
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
private class ConditionalCacheDataSinkFactory(
    private val delegateFactory: DataSink.Factory,
    private val shouldCache: () -> Boolean,
) : DataSink.Factory {
    override fun createDataSink(): DataSink = ConditionalCacheDataSink(delegateFactory, shouldCache)
}

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
private class ConditionalCacheDataSink(
    private val delegateFactory: DataSink.Factory,
    private val shouldCache: () -> Boolean,
) : DataSink {
    private var delegate: DataSink? = null

    override fun open(dataSpec: DataSpec) {
        delegate = if (shouldCache()) delegateFactory.createDataSink().also { it.open(dataSpec) } else null
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        delegate?.write(buffer, offset, length)
    }

    override fun close() {
        delegate?.close()
        delegate = null
    }
}

private class MediaPreflightException(
    val responseCode: Int,
    val retryAfterSeconds: Long?,
    message: String,
) : IOException(message)

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
fun mergeRemoteTrackSources(primary: MediaSource, audio: MediaSource): MediaSource =
    MergingMediaSource(
        false,
        true,
        primary,
        audio,
    )

private fun trackSummary(tracks: Tracks): String {
    if (tracks.groups.isEmpty()) return "none"
    return tracks.groups.joinToString(separator = "; ") { group ->
        val selected = (0 until group.length).filter(group::isTrackSelected)
        val supported = (0 until group.length).count(group::isTrackSupported)
        val formatIndex = selected.firstOrNull() ?: 0
        val format = group.getTrackFormat(formatIndex)
        "${trackTypeName(group.type)}(selected=${selected.joinToString(",")}," +
            "supported=$supported/${group.length},mime=${format.sampleMimeType ?: "unknown"}," +
            "codecs=${format.codecs ?: "unknown"},channels=${format.channelCount}," +
            "sampleRate=${format.sampleRate})"
    }
}

private fun trackTypeName(type: Int): String = when (type) {
    C.TRACK_TYPE_AUDIO -> "audio"
    C.TRACK_TYPE_VIDEO -> "video"
    C.TRACK_TYPE_TEXT -> "text"
    C.TRACK_TYPE_IMAGE -> "image"
    else -> "type-$type"
}

internal fun clearTransientPlaybackBannerOnReady(state: ReceiverUiState): ReceiverUiState {
    val banner = state.banner ?: return state
    return if (banner.startsWith("网络不稳定") || banner.startsWith("播放失败")) {
        state.copy(banner = null, bannerIsError = false)
    } else {
        state
    }
}

internal fun playbackFailureBanner(errorCode: String, httpStatus: Int?): String = when (httpStatus) {
    403 -> "播放地址已失效或媒体服务器拒绝访问（HTTP 403），请在发送端重新解析"
    404 -> "媒体文件不存在（HTTP 404），请在发送端重新解析"
    416 -> "媒体缓存与播放源不一致（HTTP 416），请重新投放"
    null -> "播放失败：$errorCode"
    else -> "媒体服务器返回 HTTP $httpStatus，播放已暂停"
}

private fun playbackHttpResponseCode(error: Throwable): Int? {
    var current: Throwable? = error
    repeat(8) {
        val cause = current ?: return null
        if (cause is HttpDataSource.InvalidResponseCodeException) return cause.responseCode
        current = cause.cause
    }
    return null
}

private fun playbackErrorCauses(error: Throwable): String {
    val causes = mutableListOf<String>()
    var current: Throwable? = error
    repeat(8) {
        val cause = current ?: return@repeat
        val responseCode = (cause as? HttpDataSource.InvalidResponseCodeException)?.responseCode
        causes += if (responseCode == null) {
            cause.javaClass.simpleName
        } else {
            "${cause.javaClass.simpleName}(http=$responseCode)"
        }
        current = cause.cause
    }
    return causes.distinct().joinToString(" -> ")
}

internal fun shouldPrepareForPlay(playbackState: Int, mediaItemCount: Int): Boolean =
    playbackState == Player.STATE_IDLE && mediaItemCount > 0

private class EtagPreflightInterceptor(private val expectedEtag: String) : Interceptor {
    private val completed = AtomicBoolean(false)
    private val lock = Any()

    override fun intercept(chain: Interceptor.Chain): Response {
        if (!completed.get()) {
            synchronized(lock) {
                if (!completed.get()) {
                    val request = chain.request().newBuilder()
                        .head()
                        .removeHeader("Range")
                        .build()
                    chain.proceed(request).use { response ->
                        val retryAfter = response.header("Retry-After")?.toLongOrNull()
                        if (!response.isSuccessful) {
                            throw MediaPreflightException(
                                response.code,
                                retryAfter,
                                "Media HEAD preflight failed with HTTP ${response.code}",
                            )
                        }
                        if (response.header("ETag") != expectedEtag) {
                            throw MediaPreflightException(412, null, "Media HEAD preflight ETag mismatch")
                        }
                        completed.set(true)
                    }
                }
            }
        }
        return chain.proceed(chain.request())
    }
}

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
private class CastLoadErrorPolicy : DefaultLoadErrorHandlingPolicy(3) {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        val error = loadErrorInfo.exception
        val preflightError = error.findCause<MediaPreflightException>()
        if (preflightError != null) {
            return castHttpRetryDelay(
                preflightError.responseCode,
                loadErrorInfo.errorCount,
                preflightError.retryAfterSeconds,
            )
        }
        val responseError = error.findCause<HttpDataSource.InvalidResponseCodeException>()
        if (responseError != null) {
            val retryAfter = responseError.headerFields.entries
                .firstOrNull { it.key.equals("Retry-After", ignoreCase = true) }
                ?.value
                ?.firstOrNull()
                ?.toLongOrNull()
            return castHttpRetryDelay(responseError.responseCode, loadErrorInfo.errorCount, retryAfter)
        }
        if (error.isTransientNetworkFailure()) return castTransientRetryDelay(loadErrorInfo.errorCount)
        return super.getRetryDelayMsFor(loadErrorInfo)
    }

    private fun IOException.isTransientNetworkFailure(): Boolean {
        if (findCause<SSLException>() != null) return false
        return findCause<SocketTimeoutException>() != null ||
            findCause<SocketException>() != null ||
            findCause<UnknownHostException>() != null ||
            findCause<ConnectException>() != null ||
            findCause<NoRouteToHostException>() != null ||
            this is HttpDataSource.HttpDataSourceException
    }

    private inline fun <reified T : Throwable> Throwable.findCause(): T? {
        var current: Throwable? = this
        while (current != null) {
            if (current is T) return current
            current = current.cause
        }
        return null
    }
}
