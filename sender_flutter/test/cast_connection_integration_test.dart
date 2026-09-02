import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/protocol/protocol.dart';
import 'package:lan_media_cast_sender/services/cast_connection.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';
import 'package:lan_media_cast_sender/services/install_certificate.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'connects to a self-signed WSS receiver and completes pairing',
    () async {
      final _FakeReceiver receiver = await _FakeReceiver.start();
      final CastConnection connection = CastConnection(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      );
      addTearDown(() async {
        await connection.disconnect();
        connection.dispose();
        await receiver.close();
      });

      final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
        (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
      );
      await connection.connect(
        DeviceTarget(
          deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          deviceName: 'Test Receiver',
          address: InternetAddress.loopbackIPv4.address,
          wssPort: receiver.port,
          busy: false,
          pairingRequired: true,
        ),
      );
      final ProtocolEnvelope hello = await helloFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(hello.payload['senderId'], connection.senderId);

      await receiver.send(
        type: 'session.pairing_required',
        replyTo: hello.id,
        payload: <String, Object>{
          'challengeId': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'challengeExpiresAt': DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
        },
      );
      await _waitForPhase(connection, ConnectionPhase.pairing);
      expect(connection.pairingRequired, isTrue);

      final Future<ProtocolEnvelope> confirmFuture = receiver.messages
          .firstWhere(
            (ProtocolEnvelope envelope) =>
                envelope.type == 'session.pair.confirm',
          );
      final Future<void> confirmation = connection.confirmPairing('123456');
      final ProtocolEnvelope confirm = await confirmFuture.timeout(
        const Duration(seconds: 5),
      );
      expect(confirm.payload['pairingCode'], '123456');
      await receiver.send(
        type: 'response',
        replyTo: confirm.id,
        payload: <String, Object>{'ok': true},
      );
      await confirmation;

      const String sessionId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      await receiver.send(
        type: 'session.ready',
        sessionId: sessionId,
        payload: <String, Object>{
          'sessionId': sessionId,
          'trustedToken': 'test-trusted-token',
          'deviceId': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          'deviceName': 'Resolved Receiver',
          'playlistRevision': 12,
        },
      );
      await _waitForPhase(connection, ConnectionPhase.ready);
      expect(connection.sessionId, sessionId);
      expect(connection.errorMessage, isNull);
      expect(
        connection.target?.deviceId,
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      );
      expect(connection.target?.deviceName, 'Resolved Receiver');
      expect(connection.remotePlaylistRevision, 12);

      final Future<ProtocolEnvelope> commandFuture = receiver.messages
          .firstWhere(
            (ProtocolEnvelope envelope) => envelope.type == 'player.play',
          );
      final Future<Map<String, dynamic>> commandResponse = connection
          .sendCommand('player.play');
      final ProtocolEnvelope command = await commandFuture.timeout(
        const Duration(seconds: 5),
      );
      await receiver.send(
        type: 'response',
        sessionId: sessionId,
        replyTo: command.id,
        payload: <String, Object>{'ok': true},
      );
      expect(await commandResponse, containsPair('ok', true));

      final Future<ProtocolEnvelope> invalidCommandFuture = receiver.messages
          .firstWhere(
            (ProtocolEnvelope envelope) => envelope.type == 'player.pause',
          );
      final Future<Map<String, dynamic>> invalidCommandResponse = connection
          .sendCommand('player.pause');
      final Future<void> disconnectExpectation = expectLater(
        connection.waitForEvent(
          (_) => false,
          timeout: const Duration(minutes: 1),
        ),
        throwsA(isA<StateError>()),
      );
      final ProtocolEnvelope invalidCommand = await invalidCommandFuture
          .timeout(const Duration(seconds: 5));
      await receiver.send(
        type: 'Invalid Response',
        sessionId: sessionId,
        replyTo: invalidCommand.id,
        payload: <String, Object>{'ok': true},
      );
      await expectLater(
        invalidCommandResponse.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message.toString(),
            'message',
            allOf(
              contains('接收端 -> 发送端'),
              contains('Invalid message type: "Invalid Response"'),
            ),
          ),
        ),
      );
      await disconnectExpectation.timeout(const Duration(seconds: 2));

      final Future<ProtocolEnvelope> reconnectHelloFuture = receiver.messages
          .firstWhere(
            (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
          );
      await connection.connect(
        DeviceTarget(
          deviceId:
              'manual-${InternetAddress.loopbackIPv4.address}-${receiver.port}',
          deviceName: InternetAddress.loopbackIPv4.address,
          address: InternetAddress.loopbackIPv4.address,
          wssPort: receiver.port,
          busy: false,
          pairingRequired: true,
        ),
      );
      final ProtocolEnvelope reconnectHello = await reconnectHelloFuture
          .timeout(const Duration(seconds: 5));
      expect(reconnectHello.payload['trustedToken'], 'test-trusted-token');
    },
  );

  test('reuses trust created by a manual endpoint after discovery', () async {
    final _FakeReceiver receiver = await _FakeReceiver.start();
    final String manualId =
        'manual-${InternetAddress.loopbackIPv4.address}-${receiver.port}';
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'receiver_pin_$manualId': receiver.certificatePin,
      'receiver_token_$manualId': 'manual-trusted-token',
    });
    final CastConnection connection = CastConnection(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    );
    addTearDown(() async {
      await connection.disconnect();
      connection.dispose();
      await receiver.close();
    });

    final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
      (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
    );
    await connection.connect(
      DeviceTarget(
        deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        deviceName: 'Resolved Receiver',
        address: InternetAddress.loopbackIPv4.address,
        wssPort: receiver.port,
        busy: false,
        pairingRequired: false,
      ),
    );

    final ProtocolEnvelope hello = await helloFuture.timeout(
      const Duration(seconds: 5),
    );
    expect(hello.payload['trustedToken'], 'manual-trusted-token');
  });

  test(
    'a changed certificate stops reconnecting and withholds the token until re-trusted',
    () async {
      final _FakeReceiver receiver = await _FakeReceiver.start();
      final String manualId =
          'manual-${InternetAddress.loopbackIPv4.address}-${receiver.port}';
      final String stalePin = receiver.certificatePin.replaceFirst(
        receiver.certificatePin[0],
        receiver.certificatePin[0] == 'A' ? 'B' : 'A',
      );
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'receiver_pin_$manualId': stalePin,
        'receiver_token_$manualId': 'manual-trusted-token',
      });
      final CastConnection connection = CastConnection(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      );
      addTearDown(() async {
        await connection.disconnect();
        connection.dispose();
        await receiver.close();
      });

      await connection.connect(
        DeviceTarget(
          deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          deviceName: 'Resolved Receiver',
          address: InternetAddress.loopbackIPv4.address,
          wssPort: receiver.port,
          busy: false,
          pairingRequired: false,
        ),
      );

      // The stale pin must be honoured: the handshake fails and, because
      // retrying can never succeed, reconnection stops instead of looping.
      expect(connection.certificateChanged, isTrue);
      expect(connection.phase, ConnectionPhase.disconnected);

      final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
        (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
      );
      await connection.trustChangedReceiver();
      final ProtocolEnvelope hello = await helloFuture.timeout(
        const Duration(seconds: 5),
      );

      // Re-trusting drops the old credentials, so the token issued to the
      // previous identity is not replayed to the new one.
      expect(connection.certificateChanged, isFalse);
      expect(hello.payload['trustedToken'], isNull);
    },
  );

  test('withholds the trusted token when the certificate is unpinned', () async {
    final _FakeReceiver receiver = await _FakeReceiver.start();
    final String manualId =
        'manual-${InternetAddress.loopbackIPv4.address}-${receiver.port}';
    // A token with no matching pin: the peer's certificate cannot be verified,
    // so the bearer credential must not leave the sender.
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'receiver_token_$manualId': 'manual-trusted-token',
    });
    final CastConnection connection = CastConnection(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    );
    addTearDown(() async {
      await connection.disconnect();
      connection.dispose();
      await receiver.close();
    });

    final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
      (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
    );
    await connection.connect(
      DeviceTarget(
        deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        deviceName: 'Resolved Receiver',
        address: InternetAddress.loopbackIPv4.address,
        wssPort: receiver.port,
        busy: false,
        pairingRequired: false,
      ),
    );

    final ProtocolEnvelope hello = await helloFuture.timeout(
      const Duration(seconds: 5),
    );
    expect(hello.payload['trustedToken'], isNull);
  });

  test('receiver busy ends the handshake without reconnecting', () async {
    final _FakeReceiver receiver = await _FakeReceiver.start();
    final CastConnection connection = CastConnection(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    );
    int helloCount = 0;
    final StreamSubscription<ProtocolEnvelope> messages = receiver.messages
        .listen((ProtocolEnvelope envelope) {
          if (envelope.type == 'session.hello') helloCount += 1;
        });
    addTearDown(() async {
      await messages.cancel();
      await connection.disconnect();
      connection.dispose();
      await receiver.close();
    });

    final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
      (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
    );
    await connection.connect(_targetFor(receiver));
    await helloFuture.timeout(const Duration(seconds: 5));
    await receiver.send(
      type: 'session.receiver_busy',
      payload: <String, Object>{'retryAfterMs': 5000},
    );

    await _waitForPhase(connection, ConnectionPhase.disconnected);
    expect(connection.errorMessage, '投影仪正被其他设备使用');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(helloCount, 1);
  });

  test('unsupported protocol version is terminal and visible', () async {
    final _FakeReceiver receiver = await _FakeReceiver.start();
    final CastConnection connection = CastConnection(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    );
    int helloCount = 0;
    final StreamSubscription<ProtocolEnvelope> messages = receiver.messages
        .listen((ProtocolEnvelope envelope) {
          if (envelope.type == 'session.hello') helloCount += 1;
        });
    addTearDown(() async {
      await messages.cancel();
      await connection.disconnect();
      connection.dispose();
      await receiver.close();
    });

    final Future<ProtocolEnvelope> helloFuture = receiver.messages.firstWhere(
      (ProtocolEnvelope envelope) => envelope.type == 'session.hello',
    );
    await connection.connect(_targetFor(receiver));
    await helloFuture.timeout(const Duration(seconds: 5));
    await receiver.send(
      type: 'session.unsupported_version',
      payload: <String, Object>{'protocolMin': 2, 'protocolMax': 3},
    );

    await _waitForPhase(connection, ConnectionPhase.disconnected);
    expect(connection.errorMessage, '协议版本不兼容（接收端支持 2-3）');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(helloCount, 1);
  });
}

DeviceTarget _targetFor(_FakeReceiver receiver) => DeviceTarget(
  deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  deviceName: 'Test Receiver',
  address: InternetAddress.loopbackIPv4.address,
  wssPort: receiver.port,
  busy: false,
  pairingRequired: true,
);

Future<void> _waitForPhase(
  CastConnection connection,
  ConnectionPhase expected,
) async {
  if (connection.phase == expected) return;
  final Completer<void> completer = Completer<void>();
  late void Function() listener;
  listener = () {
    if (connection.phase == expected && !completer.isCompleted) {
      completer.complete();
    }
  };
  connection.addListener(listener);
  try {
    await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    connection.removeListener(listener);
  }
}

class _FakeReceiver {
  _FakeReceiver._(this._server, this.certificatePin);

  final HttpServer _server;
  final String certificatePin;
  final StreamController<ProtocolEnvelope> _messages =
      StreamController<ProtocolEnvelope>.broadcast();
  final Completer<WebSocket> _socket = Completer<WebSocket>();

  int get port => _server.port;
  Stream<ProtocolEnvelope> get messages => _messages.stream;

  static Future<_FakeReceiver> start() async {
    final InstallCertificate certificate = InstallCertificateStore().generate();
    final SecurityContext securityContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificate.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(certificate.privateKeyPem));
    final HttpServer server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      securityContext,
    );
    final _FakeReceiver receiver = _FakeReceiver._(
      server,
      certificate.sha256Base64Url,
    );
    server.listen(receiver._handleRequest);
    return receiver;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/v1/control' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final WebSocket socket = await WebSocketTransformer.upgrade(request);
    if (!_socket.isCompleted) _socket.complete(socket);
    socket.listen((dynamic raw) {
      if (raw is String) _messages.add(ProtocolEnvelope.decode(raw));
    });
  }

  Future<void> send({
    required String type,
    required Map<String, Object> payload,
    String? replyTo,
    String? sessionId,
  }) async {
    final WebSocket socket = await _socket.future.timeout(
      const Duration(seconds: 5),
    );
    socket.add(
      jsonEncode(<String, Object>{
        'v': protocolVersion,
        'type': type,
        'replyTo': ?replyTo,
        'sessionId': ?sessionId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'payload': payload,
      }),
    );
  }

  Future<void> close() async {
    if (_socket.isCompleted) {
      await (await _socket.future).close();
    }
    await _server.close(force: true);
    await _messages.close();
  }
}
