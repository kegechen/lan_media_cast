import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:lan_media_cast_sender/services/cast_connection.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';
import 'package:lan_media_cast_sender/services/install_certificate.dart';
import 'package:lan_media_cast_sender/services/local_media_server.dart';
import 'package:lan_media_cast_sender/services/yt_dlp_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> _build(_ReadyConnection connection) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return AppController.createForTesting(
    senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    discovery: DeviceDiscovery(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    ),
    connection: connection,
    mediaServer: _FakeLocalMediaServer(),
    webVideoResolver: _NoticeResolver(),
    preferences: preferences,
  );
}

const String _notice = '未能读取 Chrome 的登录状态，已按未登录解析';

void main() {
  test('a degraded resolution survives a receiver state push', () async {
    // The status bar is transient: a successful playlist.replace clears it, and
    // _onConnectionChanged clears any non-error status on every player.state
    // push -- which arrives within milliseconds of a sync. The notice must
    // therefore live outside it.
    final _ReadyConnection connection = _ReadyConnection();
    final AppController controller = await _build(connection);
    addTearDown(controller.dispose);

    await controller.addUrl('https://video.example/watch/1');
    expect(connection.commands, contains('playlist.replace'));
    expect(controller.webVideoNotice, _notice);

    // Exactly what a receiver does after the playlist lands.
    connection.notifyListeners();

    expect(controller.webVideoNotice, _notice);
    expect(controller.statusIsError, isFalse);
  });

  test('a failed cast is not painted over by the notice', () async {
    // _send swallows command failures into an error status, so writing the
    // notice into the same channel afterwards reported a broken cast as a
    // benign green message.
    final _ReadyConnection connection = _ReadyConnection()..failCommands = true;
    final AppController controller = await _build(connection);
    addTearDown(controller.dispose);

    await controller.addUrl('https://video.example/watch/1');

    expect(controller.statusIsError, isTrue);
    expect(controller.statusMessage, contains('storage_low'));
    // The notice is still recorded, just not at the expense of the error.
    expect(controller.webVideoNotice, _notice);
  });

  test('the banner prefers an error over the notice', () async {
    // The precedence lives on the controller rather than in the widget so it
    // is testable: a swapped `??` at the render layer would silently
    // reintroduce a failed cast being shown as a benign green message.
    final AppController controller = await _build(_ReadyConnection());
    addTearDown(controller.dispose);

    controller
      ..webVideoNotice = _notice
      ..statusMessage = '接收端拒绝了播放列表：storage_low'
      ..statusIsError = true;
    expect(controller.bannerMessage, contains('storage_low'));

    // With nothing more urgent to say, the notice is what shows.
    controller
      ..statusMessage = null
      ..statusIsError = false;
    expect(controller.bannerMessage, _notice);
  });

  test('dismissing the banner clears the notice too', () async {
    final AppController controller = await _build(_ReadyConnection());
    addTearDown(controller.dispose);
    await controller.addUrl('https://video.example/watch/1');

    controller.dismissStatus();

    expect(controller.webVideoNotice, isNull);
  });
}

class _NoticeResolver implements WebVideoResolver {
  @override
  bool requiresExtraction(Uri uri) => true;

  @override
  void cancel() {}

  @override
  Future<ResolvedWebVideo> resolve(Uri uri, {YtDlpBrowser? cookieBrowser}) async =>
      ResolvedWebVideo(
        primaryTrack: ResolvedWebVideoTrack(
          url: Uri.parse('https://cdn.example/video.mp4'),
          httpHeaders: const <String, String>{},
        ),
        name: 'Example lesson',
        webpageUrl: uri,
        resolvedAt: DateTime.now().millisecondsSinceEpoch,
        notice: '未能读取 Chrome 的登录状态，已按未登录解析',
      );
}

class _ReadyConnection extends CastConnection {
  // sessionId is left null so it matches the controller's un-announced
  // session, which is what _syncPlaylist gates on before sending. `phase` is
  // set to ready because that is inseparable from isReady in production, and a
  // fake without it cannot exercise the status-clearing path at all.
  _ReadyConnection()
    : super(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      ) {
    phase = ConnectionPhase.ready;
  }

  final List<String> commands = <String>[];
  bool failCommands = false;

  @override
  bool get isReady => true;

  @override
  void notifyListeners() => super.notifyListeners();

  @override
  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    commands.add(type);
    if (failCommands) throw StateError('接收端拒绝了播放列表：storage_low');
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
  void renewSession() {}

  @override
  Future<void> stop() async {}
}
