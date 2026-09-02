import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../protocol/protocol.dart';
import 'app_log.dart';
import 'device_discovery.dart';

enum ConnectionPhase { disconnected, connecting, pairing, ready, reconnecting }

/// A command the receiver answered with `ok: false`.
///
/// Extends [StateError] so existing callers and [userFacingError] keep behaving
/// exactly as before, while carrying the protocol [code] for the few callers
/// that need to branch on it.
class ReceiverCommandRejected extends StateError {
  ReceiverCommandRejected(this.code, super.message);

  final String? code;
}

class RemotePlayerState {
  const RemotePlayerState({
    required this.state,
    required this.positionMs,
    required this.durationMs,
    required this.itemId,
    required this.repeatMode,
  });

  final String state;
  final int positionMs;
  final int durationMs;
  final String? itemId;
  final String repeatMode;

  factory RemotePlayerState.fromPayload(Map<String, dynamic> payload) =>
      RemotePlayerState(
        state: payload['state'] as String? ?? 'idle',
        positionMs: payload['positionMs'] as int? ?? 0,
        durationMs: payload['durationMs'] as int? ?? 0,
        itemId: payload['itemId'] as String?,
        repeatMode: payload['repeatMode'] as String? ?? 'playOnce',
      );
}

class CastConnection extends ChangeNotifier {
  CastConnection({
    required this.senderId,
    required this.senderName,
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final String senderId;
  final String senderName;
  final FlutterSecureStorage _secureStorage;
  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
  final Random _random = Random.secure();
  final StreamController<ProtocolEnvelope> _events =
      StreamController<ProtocolEnvelope>.broadcast();

  ConnectionPhase phase = ConnectionPhase.disconnected;
  DeviceTarget? target;
  String? sessionId;
  int? remotePlaylistRevision;
  String? errorMessage;
  RemotePlayerState? playerState;
  Future<void> Function()? onReady;

  /// Set when the receiver presented a certificate that does not match the
  /// stored pin. Reconnecting is suspended until the user resolves it through
  /// [trustChangedReceiver] or [disconnect].
  bool certificateChanged = false;

  /// Fingerprints behind [certificateChanged], so the user can compare them
  /// instead of deciding from a device name that discovery does not
  /// authenticate.
  String? pinnedFingerprint;
  String? presentedFingerprint;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Uint8List? _currentCertificateDigest;
  String? _challengeId;
  int? _challengeExpiresAt;
  int _commandSequence = 0;
  int _lastPlayerSequence = 0;
  int _reconnectAttempt = 0;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);
  bool _manualDisconnect = false;
  bool _disposed = false;

  bool get isReady => phase == ConnectionPhase.ready && _socket != null;
  bool get isDisposed => _disposed;
  bool get pairingRequired =>
      phase == ConnectionPhase.pairing && _challengeId != null;
  String? get pairingChallengeId => pairingRequired ? _challengeId : null;
  bool get canControl => isReady;
  Stream<ProtocolEnvelope> get events => _events.stream;

  Future<ProtocolEnvelope> waitForEvent(
    bool Function(ProtocolEnvelope event) predicate, {
    required Duration timeout,
  }) {
    if (!isReady) return Future<ProtocolEnvelope>.error(StateError('连接已断开'));
    final Completer<ProtocolEnvelope> completer = Completer<ProtocolEnvelope>();
    late final StreamSubscription<ProtocolEnvelope> eventSubscription;
    late final Timer timer;

    void failIfDisconnected() {
      if (!isReady && !completer.isCompleted) {
        completer.completeError(StateError('连接已断开'));
      }
    }

    eventSubscription = events.listen((ProtocolEnvelope event) {
      if (predicate(event) && !completer.isCompleted) completer.complete(event);
    });
    addListener(failIfDisconnected);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('接收端未在限定时间内响应'));
      }
    });
    failIfDisconnected();
    return completer.future.whenComplete(() async {
      timer.cancel();
      removeListener(failIfDisconnected);
      await eventSubscription.cancel();
    });
  }

  Future<void> connect(DeviceTarget device) async {
    if (_disposed) throw StateError('连接对象已释放');
    unawaited(
      AppLog.instance.info(
        'connection.connect_requested',
        fields: <String, Object?>{
          'deviceId': device.deviceId,
          'deviceName': device.deviceName,
          'address': device.address,
          'port': device.wssPort,
        },
      ),
    );
    _manualDisconnect = true;
    await _closeSocket();
    target = device;
    _manualDisconnect = false;
    certificateChanged = false;
    pinnedFingerprint = null;
    presentedFingerprint = null;
    _reconnectAttempt = 0;
    await _connectInternal(reconnecting: false);
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    target = null;
    await _closeSocket();
    phase = ConnectionPhase.disconnected;
    sessionId = null;
    remotePlaylistRevision = null;
    _challengeId = null;
    _challengeExpiresAt = null;
    errorMessage = null;
    certificateChanged = false;
    pinnedFingerprint = null;
    presentedFingerprint = null;
    _notifyListeners();
    unawaited(AppLog.instance.info('connection.disconnected_by_user'));
  }

  Future<void> confirmPairing(String pairingCode) async {
    final String? challengeId = _challengeId;
    final int? expiresAt = _challengeExpiresAt;
    if (phase != ConnectionPhase.pairing || challengeId == null) {
      throw StateError('当前没有待确认的连接');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pairingCode)) {
      throw const FormatException('请输入 6 位数字连接码');
    }
    if (expiresAt == null ||
        DateTime.now().millisecondsSinceEpoch >= expiresAt) {
      throw StateError('连接码已过期，请重新连接');
    }
    final Map<String, dynamic> result = await _sendRequest(
      type: 'session.pair.confirm',
      payload: <String, Object>{
        'challengeId': challengeId,
        'pairingCode': pairingCode,
      },
      includeCommandSequence: false,
      timeout: const Duration(seconds: 5),
    );
    _throwIfRejected(result);
  }

  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    if (!isReady) throw StateError('接收端未连接');
    final Map<String, dynamic> result = await _sendRequest(
      type: type,
      payload: payload,
      includeCommandSequence: true,
      timeout: const Duration(seconds: 3),
    );
    _throwIfRejected(result);
    return result;
  }

  void sendBinary(Uint8List bytes) {
    if (!isReady || bytes.length > maxBinaryFrameBytes) {
      throw StateError('照片分块无法在当前连接发送');
    }
    _socket!.add(bytes);
  }

  Future<void> _connectInternal({required bool reconnecting}) async {
    if (_disposed) return;
    final DeviceTarget? device = target;
    if (device == null) return;
    phase = reconnecting
        ? ConnectionPhase.reconnecting
        : ConnectionPhase.connecting;
    errorMessage = null;
    sessionId = null;
    remotePlaylistRevision = null;
    _challengeId = null;
    _challengeExpiresAt = null;
    _commandSequence = 0;
    _lastPlayerSequence = 0;
    _notifyListeners();
    unawaited(
      AppLog.instance.info(
        'connection.attempt',
        fields: <String, Object?>{
          'address': device.address,
          'port': device.wssPort,
          'reconnecting': reconnecting,
          'attempt': _reconnectAttempt + 1,
        },
      ),
    );

    final List<String> credentialDeviceIds = _credentialDeviceIds(device);
    String? credentialDeviceId;
    String? pinnedText;
    for (final String deviceId in credentialDeviceIds) {
      pinnedText = await _secureStorage.read(key: _pinKey(deviceId));
      if (pinnedText != null) {
        credentialDeviceId = deviceId;
        break;
      }
    }
    final Uint8List? expectedPin = pinnedText == null
        ? null
        : _decodeBase64Url(pinnedText);
    final HttpClient client = HttpClient(context: SecurityContext())
      ..connectionTimeout = const Duration(seconds: 3)
      ..idleTimeout = const Duration(seconds: 15);
    Uint8List? observedPin;
    bool pinMismatch = false;
    client.badCertificateCallback =
        (X509Certificate certificate, String host, int port) {
          final Uint8List actual = Uint8List.fromList(
            sha256.convert(certificate.der).bytes,
          );
          observedPin = actual;
          if (expectedPin == null) return true;
          final bool matches = _constantTimeEquals(expectedPin, actual);
          if (!matches) pinMismatch = true;
          return matches;
        };
    try {
      final WebSocket socket = await WebSocket.connect(
        'wss://${device.address}:${device.wssPort}/v1/control',
        customClient: client,
      ).timeout(const Duration(seconds: 5));
      if (observedPin == null) throw const TlsException('未取得接收端证书');
      if (expectedPin != null &&
          !_constantTimeEquals(expectedPin, observedPin!)) {
        pinMismatch = true;
        throw const TlsException('接收端身份已变化');
      }
      _currentCertificateDigest = observedPin;
      _socket = socket;
      _subscription = socket.listen(
        _onMessage,
        onDone: _onSocketDone,
        onError: _onSocketError,
        cancelOnError: true,
      );
      _lastActivity = DateTime.now();
      _startHeartbeat();
      // The trusted token is a bearer credential: only hand it over once the
      // receiver's certificate has been matched against a stored pin. On a
      // trust-on-first-use connection the peer is unverified, so we withhold it
      // and let the receiver ask for pairing instead.
      final String? trustedToken = expectedPin == null
          ? null
          : await _secureStorage.read(key: _tokenKey(credentialDeviceId!));
      _sendEnvelope(
        type: 'session.hello',
        payload: <String, Object?>{
          'senderId': senderId,
          'senderName': senderName,
          'protocolMin': 1,
          'protocolMax': 1,
          'trustedToken': trustedToken,
          'capabilities': <String>['playlist', 'photo', 'https-range'],
        },
        includeCommandSequence: false,
      );
      unawaited(
        AppLog.instance.info(
          'connection.websocket_opened',
          fields: <String, Object?>{
            'address': device.address,
            'port': device.wssPort,
          },
        ),
      );
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'connection.attempt_failed',
          error,
          stackTrace: stackTrace,
          fields: <String, Object?>{
            'address': device.address,
            'port': device.wssPort,
            'reconnecting': reconnecting,
          },
        ),
      );
      client.close(force: true);
      errorMessage = _connectionError(error);
      await _closeSocket();
      if (pinMismatch) {
        _enterCertificateChanged(expectedPin, observedPin);
        return;
      }
      _scheduleReconnect();
    }
  }

  /// The stored pin no longer matches the receiver. Retrying can never succeed,
  /// so stop reconnecting and wait for the user to decide whether to re-trust.
  void _enterCertificateChanged(Uint8List? expected, Uint8List? presented) {
    if (_disposed) return;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    certificateChanged = true;
    pinnedFingerprint = expected == null ? null : _encodeBase64Url(expected);
    presentedFingerprint = presented == null
        ? null
        : _encodeBase64Url(presented);
    errorMessage = '接收端身份已变化，需要重新确认信任';
    phase = ConnectionPhase.disconnected;
    sessionId = null;
    remotePlaylistRevision = null;
    _challengeId = null;
    _challengeExpiresAt = null;
    _notifyListeners();
    unawaited(
      AppLog.instance.warning(
        'connection.certificate_changed',
        fields: <String, Object?>{
          'address': target?.address,
          'port': target?.wssPort,
        },
      ),
    );
  }

  /// Drops the stored pin and token for the current target and reconnects.
  ///
  /// Only call this after the user has explicitly confirmed the change. The
  /// token is dropped together with the pin so the new identity has to be
  /// re-established through pairing rather than by replaying a credential that
  /// was issued to the previous one.
  Future<void> trustChangedReceiver() async {
    if (_disposed) throw StateError('连接对象已释放');
    final DeviceTarget? device = target;
    if (device == null || !certificateChanged) {
      throw StateError('当前没有待重新信任的接收端');
    }
    unawaited(
      AppLog.instance.warning(
        'connection.certificate_retrusted',
        fields: <String, Object?>{
          'address': device.address,
          'port': device.wssPort,
        },
      ),
    );
    try {
      for (final String deviceId in _credentialDeviceIds(device)) {
        await _secureStorage.delete(key: _pinKey(deviceId));
        await _secureStorage.delete(key: _tokenKey(deviceId));
      }
    } on Object {
      // Stay in the certificate-changed state so the prompt can be raised
      // again; silently clearing it would strand the connection with no way
      // back short of restarting the app.
      errorMessage = '无法清除接收端信任信息，请重试';
      _notifyListeners();
      rethrow;
    }
    certificateChanged = false;
    pinnedFingerprint = null;
    presentedFingerprint = null;
    errorMessage = null;
    _manualDisconnect = false;
    _reconnectAttempt = 0;
    _notifyListeners();
    await _connectInternal(reconnecting: false);
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    _lastActivity = DateTime.now();
    if (raw is! String) return;
    try {
      final ProtocolEnvelope envelope = ProtocolEnvelope.decode(raw);
      _events.add(envelope);
      switch (envelope.type) {
        case 'session.pairing_required':
          _handlePairingRequired(envelope);
        case 'session.ready':
          unawaited(_handleReady(envelope));
        case 'session.ping':
          _sendEnvelope(
            type: 'session.pong',
            payload: envelope.payload,
            includeCommandSequence: false,
          );
        case 'session.pong':
          break;
        case 'response':
        case 'photo.batch.ready':
        case 'photo.item.ready':
        case 'photo.batch.resume.state':
          final String? replyTo = envelope.replyTo;
          if (replyTo != null) _pending[replyTo]?.complete(envelope.payload);
        case 'player.state':
          final int sequence = envelope.payload['sequence'] as int? ?? 0;
          if (envelope.sessionId == sessionId &&
              sequence > _lastPlayerSequence) {
            _lastPlayerSequence = sequence;
            playerState = RemotePlayerState.fromPayload(envelope.payload);
            _notifyListeners();
          }
        case 'session.rejected':
        case 'session.receiver_busy':
          _terminateHandshake(
            envelope.type == 'session.receiver_busy'
                ? '投影仪正被其他设备使用'
                : '投影仪拒绝了连接',
          );
        case 'session.unsupported_version':
          final int? protocolMin = envelope.payload['protocolMin'] as int?;
          final int? protocolMax = envelope.payload['protocolMax'] as int?;
          final String supportedRange =
              protocolMin != null && protocolMax != null
              ? '（接收端支持 $protocolMin-$protocolMax）'
              : '';
          _terminateHandshake('协议版本不兼容$supportedRange');
        case 'protocol.error':
          errorMessage = '协议错误：${envelope.payload['reason'] ?? 'unknown'}';
          _notifyListeners();
        default:
          break;
      }
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'connection.invalid_message',
          error,
          stackTrace: stackTrace,
        ),
      );
      final StateError protocolFailure = StateError(
        '收到无效消息（接收端 -> 发送端）：$error',
      );
      errorMessage = protocolFailure.message.toString();
      _failPendingCommands(protocolFailure);
      _notifyListeners();
      final WebSocket? socket = _socket;
      if (socket != null) {
        unawaited(
          socket.close(WebSocketStatus.protocolError, 'invalid_message'),
        );
      }
    }
  }

  void _terminateHandshake(String message) {
    if (_disposed) return;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    errorMessage = message;
    phase = ConnectionPhase.disconnected;
    sessionId = null;
    remotePlaylistRevision = null;
    _challengeId = null;
    _challengeExpiresAt = null;
    _notifyListeners();
    unawaited(_closeSocket());
  }

  void _handlePairingRequired(ProtocolEnvelope envelope) {
    final String? challengeId = envelope.payload['challengeId'] as String?;
    final int? challengeExpiresAt =
        envelope.payload['challengeExpiresAt'] as int?;
    if (challengeId == null ||
        challengeExpiresAt == null ||
        challengeExpiresAt <= DateTime.now().millisecondsSinceEpoch ||
        _currentCertificateDigest == null) {
      errorMessage = '配对挑战无效';
      _notifyListeners();
      return;
    }
    _challengeId = challengeId;
    _challengeExpiresAt = challengeExpiresAt;
    phase = ConnectionPhase.pairing;
    _notifyListeners();
  }

  Future<void> _handleReady(ProtocolEnvelope envelope) async {
    if (_disposed) return;
    final DeviceTarget? device = target;
    final Uint8List? certificateDigest = _currentCertificateDigest;
    final String? readySession = envelope.payload['sessionId'] as String?;
    final String? trustedToken = envelope.payload['trustedToken'] as String?;
    if (device == null ||
        certificateDigest == null ||
        readySession == null ||
        trustedToken == null) {
      _terminateHandshake('接收端就绪消息不完整');
      return;
    }
    final String? readyDeviceId = envelope.payload['deviceId'] as String?;
    final String? readyDeviceName = envelope.payload['deviceName'] as String?;
    final int? readyPlaylistRevision =
        envelope.payload['playlistRevision'] as int?;
    final bool hasReadyIdentity =
        readyDeviceId != null &&
        isValidUuid(readyDeviceId) &&
        readyDeviceName != null &&
        utf8.encode(readyDeviceName).length <= maxNameBytes &&
        readyDeviceName.isNotEmpty;
    if (readyPlaylistRevision == null || readyPlaylistRevision < 0) {
      _terminateHandshake('接收端就绪消息缺少播放列表版本');
      return;
    }
    final DeviceTarget resolvedDevice = hasReadyIdentity
        ? DeviceTarget(
            deviceId: readyDeviceId,
            deviceName: readyDeviceName,
            address: device.address,
            wssPort: device.wssPort,
            busy: false,
            pairingRequired: false,
            capabilities: device.capabilities,
          )
        : device;
    try {
      final Set<String> resolvedCredentialIds = <String>{
        resolvedDevice.deviceId,
        _manualDeviceId(resolvedDevice),
      };
      for (final String deviceId in resolvedCredentialIds) {
        await _secureStorage.write(
          key: _pinKey(deviceId),
          value: _encodeBase64Url(certificateDigest),
        );
        await _secureStorage.write(
          key: _tokenKey(deviceId),
          value: trustedToken,
        );
      }
      target = resolvedDevice;
      sessionId = readySession;
      remotePlaylistRevision = readyPlaylistRevision;
      phase = ConnectionPhase.ready;
      _challengeId = null;
      _challengeExpiresAt = null;
      _reconnectAttempt = 0;
      _notifyListeners();
      unawaited(
        AppLog.instance.info(
          'connection.ready',
          fields: <String, Object?>{
            'deviceId': resolvedDevice.deviceId,
            'deviceName': resolvedDevice.deviceName,
            'address': resolvedDevice.address,
            'port': resolvedDevice.wssPort,
            'playlistRevision': readyPlaylistRevision,
          },
        ),
      );
      await onReady?.call();
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'connection.ready_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      errorMessage = '无法保存接收端信任信息：${error.runtimeType}';
      _notifyListeners();
      final WebSocket? socket = _socket;
      if (socket != null) {
        await socket.close(
          WebSocketStatus.internalServerError,
          'secure_storage_failed',
        );
      }
    }
  }

  String _sendEnvelope({
    required String type,
    required Map<String, dynamic> payload,
    required bool includeCommandSequence,
    String? id,
  }) {
    final WebSocket? socket = _socket;
    if (socket == null) throw StateError('控制连接未建立');
    if (!isValidMessageType(type)) {
      throw ProtocolException(
        'invalid_message',
        '拒绝发送无效消息类型：${jsonEncode(type)}',
      );
    }
    final String messageId = id ?? const Uuid().v4();
    final Map<String, dynamic> envelope = <String, dynamic>{
      'v': protocolVersion,
      'type': type,
      'id': messageId,
      if (sessionId != null) 'sessionId': sessionId,
      if (includeCommandSequence) 'commandSeq': ++_commandSequence,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    };
    socket.add(jsonEncode(envelope));
    return messageId;
  }

  Future<Map<String, dynamic>> _sendRequest({
    required String type,
    required Map<String, dynamic> payload,
    required bool includeCommandSequence,
    required Duration timeout,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final String id = const Uuid().v4();
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _sendEnvelope(
        type: type,
        payload: payload,
        includeCommandSequence: includeCommandSequence,
        id: id,
      );
      final Map<String, dynamic> result = await completer.future.timeout(
        timeout,
      );
      stopwatch.stop();
      unawaited(
        AppLog.instance.info(
          'control.command_completed',
          fields: <String, Object?>{
            'type': type,
            'ok': result['ok'],
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        ),
      );
      return result;
    } on Object catch (error, stackTrace) {
      stopwatch.stop();
      unawaited(
        AppLog.instance.error(
          'control.command_failed',
          error,
          stackTrace: stackTrace,
          fields: <String, Object?>{
            'type': type,
            'elapsedMs': stopwatch.elapsedMilliseconds,
          },
        ),
      );
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void _throwIfRejected(Map<String, dynamic> result) {
    if (result['ok'] == true) return;
    final Object? rawError = result['error'];
    final String? code = rawError is Map<String, dynamic>
        ? rawError['code'] as String?
        : null;
    final String message = switch (code) {
      'pairing_failed' => '连接码错误，请核对投影仪上的 6 位数字',
      'pairing_expired' => '连接码已过期，请重新连接',
      'pairing_locked' => '连接码错误次数过多，请稍后重试',
      'item_not_found' => '播放项目不存在或已失效',
      'invalid_message' => '命令参数无效',
      _ when rawError is Map<String, dynamic> =>
        rawError['message'] as String? ?? '命令被拒绝',
      _ => '命令被拒绝',
    };
    throw ReceiverCommandRejected(code, message);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final WebSocket? socket = _socket;
      if (socket == null) return;
      if (DateTime.now().difference(_lastActivity) >=
          const Duration(seconds: 15)) {
        unawaited(socket.close(WebSocketStatus.goingAway, 'heartbeat_timeout'));
        return;
      }
      _sendEnvelope(
        type: 'session.ping',
        payload: <String, Object>{
          'nonce': const Uuid().v4(),
          'sentAt': DateTime.now().millisecondsSinceEpoch,
        },
        includeCommandSequence: false,
      );
    });
  }

  void _onSocketDone() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription = null;
    _socket = null;
    _failPendingCommands();
    unawaited(
      AppLog.instance.warning(
        'connection.socket_closed',
        fields: <String, Object?>{'manual': _manualDisconnect},
      ),
    );
    if (!_disposed && !_manualDisconnect) _scheduleReconnect();
  }

  void _onSocketError(Object error, [StackTrace? stackTrace]) {
    unawaited(
      AppLog.instance.error(
        'connection.socket_error',
        error,
        stackTrace: stackTrace,
      ),
    );
    errorMessage = _connectionError(error);
    _onSocketDone();
  }

  void _scheduleReconnect() {
    if (_disposed ||
        _manualDisconnect ||
        target == null ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    phase = ConnectionPhase.reconnecting;
    sessionId = null;
    remotePlaylistRevision = null;
    _notifyListeners();
    const List<int> delays = <int>[500, 1000, 2000, 4000, 8000, 10000];
    final int base = delays[min(_reconnectAttempt, delays.length - 1)];
    _reconnectAttempt += 1;
    final int jitter = _random.nextInt(max(1, base ~/ 5));
    unawaited(
      AppLog.instance.info(
        'connection.reconnect_scheduled',
        fields: <String, Object?>{
          'attempt': _reconnectAttempt,
          'delayMs': base + jitter,
        },
      ),
    );
    _reconnectTimer = Timer(Duration(milliseconds: base + jitter), () {
      unawaited(_connectInternal(reconnecting: true));
    });
  }

  Future<void> _closeSocket() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final WebSocket? socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure, 'client_close');
    _failPendingCommands();
  }

  void _failPendingCommands([Object? failure]) {
    final Object reason = failure ?? StateError('连接已断开');
    for (final Completer<Map<String, dynamic>> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(reason);
    }
    _pending.clear();
  }

  String _manualDeviceId(DeviceTarget device) =>
      'manual-${device.address}-${device.wssPort}';

  /// Credentials are written under both the resolved device id and the
  /// address-derived manual id, so a lookup has to consider both: a receiver
  /// first reached manually and later found through discovery (or the reverse)
  /// must still resolve to the same stored pin.
  List<String> _credentialDeviceIds(DeviceTarget device) => <String>{
    device.deviceId,
    _manualDeviceId(device),
  }.toList(growable: false);
  String _pinKey(String deviceId) => 'receiver_pin_$deviceId';
  String _tokenKey(String deviceId) => 'receiver_token_$deviceId';
  String _encodeBase64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
  Uint8List _decodeBase64Url(String value) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    int difference = 0;
    for (int index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  String _connectionError(Object error) {
    if (error is TlsException) return error.message;
    if (error is TimeoutException) return '连接超时，请检查网络或防火墙';
    if (error is SocketException) return '无法连接投影仪，请检查网络';
    return '连接失败：${error.runtimeType}';
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_closeSocket());
    unawaited(_events.close());
    super.dispose();
  }
}
