package com.iflytek.lanmediacast.receiver.network

import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.iflytek.lanmediacast.receiver.core.PairingRequest
import com.iflytek.lanmediacast.receiver.core.ReceiverRuntime
import com.iflytek.lanmediacast.receiver.playback.PlaybackCoordinator
import com.iflytek.lanmediacast.receiver.photo.PhotoBinaryException
import com.iflytek.lanmediacast.receiver.photo.PhotoExplainCoordinator
import com.iflytek.lanmediacast.receiver.protocol.Envelope
import com.iflytek.lanmediacast.receiver.protocol.PhotoChunkCodec
import com.iflytek.lanmediacast.receiver.protocol.ProtocolCodec
import com.iflytek.lanmediacast.receiver.protocol.ProtocolException
import com.iflytek.lanmediacast.receiver.protocol.ProtocolLimits
import com.iflytek.lanmediacast.receiver.security.ReceiverIdentity
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake

internal fun photoInternalErrorPayload(transferId: String?): JsonObject = buildJsonObject {
    put("ok", false)
    put("code", "internal_error")
    put("reason", "internal_error")
    put("transferId", transferId?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
}

internal fun commandRevealsMedia(type: String, payload: JsonObject): Boolean =
    type == "player.select" && payload["ok"]?.jsonPrimitive?.contentOrNull == "true"

class CastSessionServer(
    port: Int,
    private val identity: ReceiverIdentity,
    private val playback: PlaybackCoordinator,
    private val photos: PhotoExplainCoordinator,
) : SecureWebSocketServer(port, identity.createServerSslContext()) {
    private data class PendingHandshake(
        val connection: WebSocket,
        val senderId: String,
        val senderName: String,
        val challenge: PairingChallenge,
    )

    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "cast-heartbeat").apply { isDaemon = true }
    }
    private val connection = AtomicReference<WebSocket?>(null)
    private val pairingRateLimiter = PairingRateLimiter()
    private val secureRandom = SecureRandom()
    private var ledger = CommandLedger()
    private var pending: PendingHandshake? = null
    @Volatile
    private var sessionId: String? = null
    private var senderName: String? = null
    private var senderId: String? = null
    private var lastActivityElapsed = SystemClock.elapsedRealtime()
    private var heartbeat: ScheduledFuture<*>? = null

    val isBusy: Boolean
        get() = connection.get() != null

    override fun onStart() {
        Log.i(TAG, "WSS control server listening on $port")
        heartbeat = scheduler.scheduleWithFixedDelay(::heartbeatTick, 5, 5, TimeUnit.SECONDS)
    }

    @Synchronized
    override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
        if (handshake.resourceDescriptor != CONTROL_PATH) {
            conn.close(1008, "invalid_path")
            return
        }
        if (!connection.compareAndSet(null, conn)) {
            conn.send(event("session.receiver_busy", null, buildJsonObject {
                put("deviceName", identity.deviceName)
                put("retryAfterMs", 5_000)
            }))
            conn.close(1008, "receiver_busy")
            return
        }
        lastActivityElapsed = SystemClock.elapsedRealtime()
        photos.beginConnection()
        ReceiverRuntime.update { it.copy(banner = "正在建立安全连接", bannerIsError = false) }
    }

    @Synchronized
    override fun onMessage(conn: WebSocket, message: String) {
        if (conn != connection.get()) return
        lastActivityElapsed = SystemClock.elapsedRealtime()
        val envelope = try {
            ProtocolCodec.decodeEnvelope(message)
        } catch (error: ProtocolException) {
            Log.w(TAG, "Rejected sender message: code=${error.code}, detail=${error.message}")
            conn.send(errorResponse(null, error.code, error.message ?: "Invalid message"))
            if (error.code == "message_too_large") conn.close(1009, error.code)
            return
        }
        when (envelope.type) {
            "session.hello" -> handleHello(conn, envelope)
            "session.pair.confirm" -> handlePairConfirm(conn, envelope)
            "session.ping" -> conn.send(event("session.pong", sessionId, envelope.payload))
            "session.pong" -> Unit
            else -> handleCommand(conn, envelope)
        }
    }

    @Synchronized
    override fun onMessage(conn: WebSocket, message: ByteBuffer) {
        if (conn != connection.get()) return
        lastActivityElapsed = SystemClock.elapsedRealtime()
        if (message.remaining() > ProtocolLimits.MAX_BINARY_FRAME_BYTES) {
            conn.close(1009, "binary_frame_too_large")
            return
        }
        val diagnosticTransferId = runCatching {
            val copy = message.asReadOnlyBuffer()
            val bytes = ByteArray(copy.remaining()).also(copy::get)
            PhotoChunkCodec.decode(bytes).transferId.toString()
        }.getOrNull()
        try {
            photos.handleBinary(message)
        } catch (error: PhotoBinaryException) {
            conn.send(event("protocol.error", sessionId, buildJsonObject {
                put("ok", false)
                put("code", when (error.reason) {
                    "malformed_binary_header" -> "invalid_message"
                    "unknown_transfer" -> "invalid_state"
                    else -> "internal_error"
                })
                put("reason", error.reason)
                put("transferId", error.transferId?.let(::JsonPrimitive) ?: JsonPrimitive(null as String?))
            }))
            if (error.closeConnection) conn.close(1002, error.reason)
        } catch (error: Exception) {
            Log.e(TAG, "Photo binary processing failed", error)
            conn.send(event("protocol.error", sessionId, photoInternalErrorPayload(diagnosticTransferId)))
            ReceiverRuntime.update {
                it.copy(banner = "照片传输内部错误，其他播放不受影响", bannerIsError = true)
            }
        }
    }

    @Synchronized
    override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) {
        if (!connection.compareAndSet(conn, null)) return
        pending = null
        sessionId = null
        senderId = null
        senderName = null
        ReceiverRuntime.update {
            it.copy(
                connectedSender = null,
                pairingRequest = null,
                banner = if (playback.cacheAvailable()) "连接已断开，缓存内容仍可播放" else "连接已断开，等待重新连接",
                bannerIsError = false,
            )
        }
    }

    @Synchronized
    override fun onError(conn: WebSocket?, ex: Exception) {
        Log.e(TAG, "WSS server error", ex)
        ReceiverRuntime.update { it.copy(banner = "控制连接错误，正在等待重连", bannerIsError = true) }
    }

    fun sendPlayerState(payload: JsonObject) {
        val active = connection.get() ?: return
        val activeSession = sessionId ?: return
        if (active.isOpen) active.send(event("player.state", activeSession, payload))
    }

    fun sendSessionEvent(type: String, payload: JsonObject) {
        val active = connection.get() ?: return
        val activeSession = sessionId ?: return
        if (active.isOpen) active.send(event(type, activeSession, payload))
    }

    fun shutdown() {
        heartbeat?.cancel(true)
        scheduler.shutdownNow()
        try {
            stop(1_000)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun handleHello(conn: WebSocket, envelope: Envelope) {
        if (sessionId != null || pending != null) {
            conn.send(errorResponse(envelope.id, "invalid_state", "Handshake already started"))
            return
        }
        val id = envelope.payload["senderId"]?.jsonPrimitive?.contentOrNull
        val name = envelope.payload["senderName"]?.jsonPrimitive?.contentOrNull
        val trustedToken = envelope.payload["trustedToken"]?.jsonPrimitive?.contentOrNull
        if (id == null || name.isNullOrBlank()) {
            conn.send(errorResponse(envelope.id, "invalid_message", "Invalid session.hello payload"))
            return
        }
        try {
            UUID.fromString(id)
        } catch (_: IllegalArgumentException) {
            conn.send(errorResponse(envelope.id, "invalid_message", "Invalid senderId"))
            return
        }
        senderId = id
        if (name.toByteArray(Charsets.UTF_8).size > ProtocolLimits.MAX_NAME_BYTES) {
            conn.send(errorResponse(envelope.id, "invalid_message", "senderName is too long"))
            return
        }
        val protocolMin = envelope.payload["protocolMin"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val protocolMax = envelope.payload["protocolMax"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        if (protocolMin == null || protocolMax == null || protocolMin > 1 || protocolMax < 1) {
            conn.send(event("session.unsupported_version", null, buildJsonObject {
                put("protocolMin", 1); put("protocolMax", 1)
            }, replyTo = envelope.id))
            conn.close(1008, "unsupported_version")
            return
        }
        senderName = name
        if (identity.verifyTrustedToken(id, trustedToken)) {
            makeReady(conn, id, senderName!!)
            return
        }
        val sourceAddress = sourceAddress(conn)
        if (!pairingRateLimiter.isAllowed(sourceAddress)) {
            conn.send(event("session.rejected", null, buildJsonObject {
                put("reason", "pairing_locked")
                put("retryAfterMs", 30_000)
            }, replyTo = envelope.id))
            conn.close(1008, "pairing_locked")
            return
        }
        val challengeId = UUID.randomUUID().toString()
        val pairingCode = PairingCode.generate(secureRandom)
        val challenge = PairingChallenge(
            id = challengeId,
            code = pairingCode,
            expiresAt = System.currentTimeMillis() + 120_000,
        )
        val request = PendingHandshake(
            connection = conn,
            senderId = id,
            senderName = senderName!!,
            challenge = challenge,
        )
        pending = request
        conn.send(event("session.pairing_required", null, buildJsonObject {
            put("challengeId", challengeId)
            put("challengeExpiresAt", challenge.expiresAt)
        }, replyTo = envelope.id))
        ReceiverRuntime.update {
            it.copy(
                banner = "新的发送端请求连接",
                bannerIsError = false,
                pairingRequest = PairingRequest(
                    senderName = request.senderName,
                    code = pairingCode,
                ),
            )
        }
    }

    private fun handlePairConfirm(conn: WebSocket, envelope: Envelope) {
        val request = pending
        val challengeId = envelope.payload["challengeId"]?.jsonPrimitive?.contentOrNull
        val submittedCode = envelope.payload["pairingCode"]?.jsonPrimitive?.contentOrNull
        if (request == null || request.connection != conn) {
            pairingRateLimiter.recordFailure(sourceAddress(conn))
            conn.send(errorResponse(envelope.id, "pairing_failed", "Pairing confirmation is invalid"))
            return
        }
        when (request.challenge.verify(challengeId, submittedCode, System.currentTimeMillis())) {
            PairingDecision.ACCEPTED -> {
                pending = null
                conn.send(response(envelope.id, buildJsonObject { put("ok", true) }))
                makeReady(request.connection, request.senderId, request.senderName)
            }
            PairingDecision.EXPIRED, PairingDecision.ALREADY_CONSUMED -> {
                pending = null
                pairingRateLimiter.recordFailure(sourceAddress(conn))
                conn.send(errorResponse(envelope.id, "pairing_expired", "Pairing challenge expired"))
                ReceiverRuntime.update {
                    it.copy(pairingRequest = null, banner = "连接码已过期，请重新连接", bannerIsError = false)
                }
                conn.close(1008, "pairing_expired")
            }
            PairingDecision.INCORRECT_CODE, PairingDecision.INVALID_CHALLENGE -> {
                pairingRateLimiter.recordFailure(sourceAddress(request.connection))
                val locked = !pairingRateLimiter.isAllowed(sourceAddress(request.connection))
                conn.send(
                    errorResponse(
                        envelope.id,
                        if (locked) "pairing_locked" else "pairing_failed",
                        if (locked) "Too many pairing attempts" else "Connection code is incorrect",
                    ),
                )
                if (locked) {
                    pending = null
                    ReceiverRuntime.update {
                        it.copy(pairingRequest = null, banner = "连接码错误次数过多，请稍后重试")
                    }
                    conn.close(1008, "pairing_locked")
                }
            }
        }
    }

    private fun makeReady(conn: WebSocket, trustedSenderId: String, trustedSenderName: String) {
        val newSessionId = UUID.randomUUID().toString()
        val newToken = identity.rotateTrustedToken(trustedSenderId)
        sessionId = newSessionId
        ledger = CommandLedger()
        playback.beginSession()
        conn.send(event("session.ready", newSessionId, buildJsonObject {
            put("sessionId", newSessionId)
            put("trustedToken", newToken)
            put("receiverCertificateSha256", identity.certificateSha256Base64Url)
            put("deviceId", identity.deviceId)
            put("deviceName", identity.deviceName)
            put("capabilities", kotlinx.serialization.json.buildJsonArray {
                add(JsonPrimitive("media")); add(JsonPrimitive("photo")); add(JsonPrimitive("cache"))
            })
            put("mode", "media")
            put("playlistRevision", playback.currentPlaylistRevision())
        }))
        ReceiverRuntime.update {
            it.copy(connectedSender = trustedSenderName, pairingRequest = null, banner = null, bannerIsError = false)
        }
    }

    private fun handleCommand(conn: WebSocket, envelope: Envelope) {
        val activeSession = sessionId
        if (activeSession == null || envelope.sessionId != activeSession || envelope.id == null || envelope.commandSeq == null) {
            conn.send(errorResponse(envelope.id, "invalid_session", "Session is not ready"))
            return
        }
        when (val decision = ledger.inspect(envelope.commandSeq, envelope.id)) {
            is CommandLedger.Decision.Cached -> conn.send(decision.response)
            is CommandLedger.Decision.Reject -> conn.send(errorResponse(envelope.id, decision.code, "Command was rejected"))
            CommandLedger.Decision.Execute -> {
                var responseType = "response"
                val payload = try {
                    when (envelope.type) {
                        "media.endpoint.announce" -> {
                            val peerAddress = conn.remoteSocketAddress?.address?.hostAddress
                            if (peerAddress == null) {
                                errorPayload("invalid_session", "Peer address is unavailable")
                            } else {
                                playback.announceEndpoint(peerAddress, envelope.payload)
                            }
                        }
                        "playlist.replace" -> playback.replacePlaylist(envelope.payload)
                        "mode.set" -> {
                            val mode = envelope.payload["mode"]?.jsonPrimitive?.contentOrNull
                            when (mode) {
                                "photo" -> {
                                    playback.enterPhotoMode()
                                    ReceiverRuntime.update { it.copy(mode = "photo") }
                                    buildJsonObject { put("ok", true) }
                                }
                                "media" -> {
                                    playback.exitPhotoMode()
                                    ReceiverRuntime.update { it.copy(mode = "media") }
                                    buildJsonObject { put("ok", true) }
                                }
                                else -> errorPayload("unsupported_mode", "Mirror mode is not available in protocol v1")
                            }
                        }
                        else -> {
                            val photoResult = photos.handleCommand(envelope.type, envelope.payload)
                            if (photoResult != null) {
                                responseType = photoResult.responseType
                                photoResult.payload
                            } else {
                                playback.execute(envelope.type, envelope.payload)
                            }
                        }
                    }
                } catch (failure: Exception) {
                    errorPayload("invalid_message", failure.message ?: "Invalid command")
                }
                val mediaModeChanged = commandRevealsMedia(envelope.type, payload) &&
                    ReceiverRuntime.state.mode != "media"
                if (mediaModeChanged) {
                    playback.exitPhotoMode()
                    ReceiverRuntime.update { it.copy(mode = "media") }
                }
                val result = event(responseType, sessionId, payload, envelope.id)
                ledger.record(envelope.commandSeq, envelope.id, result)
                conn.send(result)
                Log.d(TAG, "Handled ${envelope.type}; ok=${payload["ok"]?.jsonPrimitive?.contentOrNull}")
                if (envelope.type == "mode.set" && payload["ok"]?.jsonPrimitive?.contentOrNull == "true") {
                    sendSessionEvent("mode.state", buildJsonObject {
                        put("mode", ReceiverRuntime.state.mode)
                        put("previousMode", if (ReceiverRuntime.state.mode == "media") "photo" else "media")
                    })
                }
                if (mediaModeChanged) {
                    sendSessionEvent("mode.state", buildJsonObject {
                        put("mode", "media")
                        put("previousMode", "photo")
                    })
                }
            }
        }
    }

    @Synchronized
    private fun heartbeatTick() {
        val active = connection.get() ?: return
        val pairing = pending
        if (pairing != null && pairing.challenge.expireIfNeeded(System.currentTimeMillis())) {
            pending = null
            ReceiverRuntime.update {
                it.copy(pairingRequest = null, banner = "连接码已过期，请重新连接", bannerIsError = false)
            }
            active.close(1008, "pairing_expired")
            return
        }
        val elapsed = SystemClock.elapsedRealtime() - lastActivityElapsed
        if (elapsed >= 15_000) {
            active.close(1001, "heartbeat_timeout")
            return
        }
        active.send(event("session.ping", sessionId, buildJsonObject {
            put("nonce", UUID.randomUUID().toString())
            put("sentAt", System.currentTimeMillis())
        }))
    }

    private fun response(replyTo: String?, payload: JsonObject): String = event("response", sessionId, payload, replyTo)

    private fun errorResponse(replyTo: String?, code: String, message: String): String =
        response(replyTo, errorPayload(code, message))

    private fun errorPayload(code: String, message: String) = buildJsonObject {
        put("ok", false)
        put("error", buildJsonObject { put("code", code); put("message", message) })
    }

    private fun event(type: String, activeSessionId: String?, payload: JsonObject, replyTo: String? = null): String =
        ProtocolCodec.json.encodeToString(JsonObject.serializer(), buildJsonObject {
            ProtocolCodec.requireMessageType(type)
            put("v", 1)
            put("type", type)
            put("id", UUID.randomUUID().toString())
            if (replyTo != null) put("replyTo", replyTo)
            if (activeSessionId != null) put("sessionId", activeSessionId)
            put("ts", System.currentTimeMillis())
            put("payload", payload)
        })

    private fun decodeBase64Url(value: String?): ByteArray = try {
        if (value == null) ByteArray(0) else Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    } catch (_: IllegalArgumentException) {
        ByteArray(0)
    }

    private fun encodeBase64Url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun sourceAddress(conn: WebSocket): String =
        conn.remoteSocketAddress?.address?.hostAddress ?: "unknown"

    private companion object {
        const val TAG = "CastSessionServer"
        const val CONTROL_PATH = "/v1/control"
    }
}
