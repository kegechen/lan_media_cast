import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:lan_media_cast_sender/services/cast_connection.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';
import 'package:lan_media_cast_sender/services/install_certificate.dart';
import 'package:lan_media_cast_sender/services/local_media_server.dart';
import 'package:lan_media_cast_sender/services/yt_dlp_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('reconnect sends a playlist revision newer than the receiver', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sender_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'playlist_v1': jsonEncode(<String, Object>{
        'revision': 3,
        'repeatMode': 'playOnce',
        'items': <Map<String, Object>>[
          <String, Object>{
            'id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'name': 'lesson.mp4',
            'kind': 'url',
            'url': 'https://media.example/lesson.mp4',
          },
        ],
      }),
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final _FakeCastConnection connection = _FakeCastConnection()
      ..sessionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      ..remotePlaylistRevision = 12;
    final _FakeLocalMediaServer mediaServer = _FakeLocalMediaServer();
    final AppController controller = await AppController.createForTesting(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      discovery: DeviceDiscovery(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      ),
      connection: connection,
      mediaServer: mediaServer,
      webVideoResolver: _FakeWebVideoResolver(),
      preferences: preferences,
    );
    addTearDown(controller.dispose);

    await connection.onReady!.call();
    expect(connection.playlistRevisions, <int>[13]);
    expect(mediaServer.renewCount, 1);

    connection
      ..sessionId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
      ..remotePlaylistRevision = 20;
    await connection.onReady!.call();

    expect(connection.playlistRevisions, <int>[13, 21]);
    final Map<String, dynamic> persisted =
        jsonDecode(preferences.getString('playlist_v1')!)
            as Map<String, dynamic>;
    expect(persisted['revision'], 21);
  });

  test(
    'a successful command clears an error latch before reconnecting',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final _FakeCastConnection connection = _FakeCastConnection()
        ..sessionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        ..phase = ConnectionPhase.ready;
      final AppController controller = await AppController.createForTesting(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        discovery: DeviceDiscovery(
          senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          senderName: 'Test Sender',
        ),
        connection: connection,
        mediaServer: _FakeLocalMediaServer(),
        webVideoResolver: _FakeWebVideoResolver(),
        preferences: preferences,
      );
      addTearDown(controller.dispose);
      controller
        ..statusMessage = 'previous command failed'
        ..statusIsError = true;

      await controller.pause();

      expect(controller.statusMessage, isNull);
      expect(controller.statusIsError, isFalse);

      connection
        ..errorMessage = null
        ..phase = ConnectionPhase.reconnecting
        ..notifyListeners();

      expect(controller.statusMessage, contains('正在重连'));
      expect(controller.statusIsError, isFalse);
    },
  );

  test('web cache keys follow the resolved rendition, not signed queries', () {
    final Uri webpage = Uri.parse('https://video.example/watch/1');
    final ResolvedWebVideoTrack first = ResolvedWebVideoTrack(
      url: Uri.parse('https://cdn.example/media/video.mp4?expires=1'),
      httpHeaders: const <String, String>{},
      formatId: '137',
      contentLength: 1000,
    );
    final ResolvedWebVideoTrack refreshed = ResolvedWebVideoTrack(
      url: Uri.parse('https://cdn.example/media/video.mp4?expires=2'),
      httpHeaders: const <String, String>{},
      formatId: '137',
      contentLength: 1000,
    );
    final ResolvedWebVideoTrack changedRendition = ResolvedWebVideoTrack(
      url: refreshed.url,
      httpHeaders: const <String, String>{},
      formatId: '399',
      contentLength: 1200,
    );

    expect(
      webTrackCacheKey(webpage, 'primary', first),
      webTrackCacheKey(webpage, 'primary', refreshed),
    );
    expect(
      webTrackCacheKey(webpage, 'primary', first),
      isNot(webTrackCacheKey(webpage, 'primary', changedRendition)),
    );
  });
}

class _FakeCastConnection extends CastConnection {
  _FakeCastConnection()
    : super(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      );

  final List<int> playlistRevisions = <int>[];

  @override
  bool get isReady => sessionId != null;

  @override
  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    if (type == 'playlist.replace') {
      playlistRevisions.add(payload['revision']! as int);
    }
    return <String, dynamic>{'ok': true};
  }
}

class _FakeLocalMediaServer extends LocalMediaServer {
  _FakeLocalMediaServer()
    : super(
        certificate: InstallCertificate(
          certificatePem: '',
          privateKeyPem: '',
          certificateDer: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );

  int renewCount = 0;

  @override
  bool get isRunning => true;

  @override
  int get port => 52143;

  @override
  int get generation => 7;

  @override
  String get certificateSha256 => 'test-certificate-pin';

  @override
  String get bearerToken => 'test-bearer-token';

  @override
  void renewSession() {
    renewCount += 1;
  }

  @override
  Future<void> stop() async {}
}

class _FakeWebVideoResolver implements WebVideoResolver {
  @override
  void cancel() {}

  @override
  bool requiresExtraction(Uri uri) => false;

  @override
  Future<ResolvedWebVideo> resolve(Uri uri, {YtDlpBrowser? cookieBrowser}) =>
      throw UnimplementedError();
}
