import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:lan_media_cast_sender/services/app_log.dart';
import 'package:lan_media_cast_sender/services/cast_connection.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';
import 'package:lan_media_cast_sender/services/install_certificate.dart';
import 'package:lan_media_cast_sender/services/local_media_server.dart';
import 'package:lan_media_cast_sender/services/yt_dlp_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Splits [text] into `diagnostics.logs.get` chunk payloads on byte boundaries.
List<Map<String, dynamic>> chunksOf(String text, int chunkBytes) {
  final List<int> bytes = utf8.encode(text);
  final List<Map<String, dynamic>> chunks = <Map<String, dynamic>>[];
  int offset = 0;
  while (offset < bytes.length) {
    final int end = (offset + chunkBytes).clamp(0, bytes.length);
    chunks.add(<String, dynamic>{
      'ok': true,
      'format': 'text',
      'offset': offset,
      'nextOffset': end,
      'totalBytes': bytes.length,
      'eof': end >= bytes.length,
      'data': utf8.decode(bytes.sublist(offset, end)),
    });
    offset = end;
  }
  return chunks;
}

Future<AppController> buildController(CastConnection connection) async {
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
    webVideoResolver: _FakeWebVideoResolver(),
    preferences: preferences,
  );
}

/// Mirrors the timestamp format `AppController` uses for saved receiver logs.
String stampOf(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}'
    '${when.month.toString().padLeft(2, '0')}'
    '${when.day.toString().padLeft(2, '0')}'
    '-${when.hour.toString().padLeft(2, '0')}'
    '${when.minute.toString().padLeft(2, '0')}'
    '${when.second.toString().padLeft(2, '0')}';

Future<List<File>> receiverLogs(Directory directory) async {
  final List<File> logs = <File>[
    for (final FileSystemEntity entity in directory.listSync())
      if (entity is File && entity.uri.pathSegments.last.startsWith('receiver-'))
        entity,
  ];
  return logs;
}

void main() {
  late Directory logDirectory;

  // AppLog is a singleton whose initialize() is a no-op once set, so the
  // directory has to be established once for the whole file; per-test temp
  // directories would silently leave every later fetch writing to the first.
  setUpAll(() async {
    logDirectory = await Directory.systemTemp.createTemp('lmc-receiver-logs');
    await AppLog.instance.initialize(directory: logDirectory);
  });

  setUp(() async {
    for (final File stale in await receiverLogs(logDirectory)) {
      stale.deleteSync();
    }
  });

  tearDownAll(() async {
    if (logDirectory.existsSync()) {
      logDirectory.deleteSync(recursive: true);
    }
  });

  test('assembles a multi-chunk retrieval into one saved file', () async {
    const String log = '1 I/Tag: alpha\n2 I/Tag: beta\n3 I/Tag: gamma\n';
    final _ScriptedConnection connection = _ScriptedConnection(
      chunksOf(log, 12),
    );
    final AppController controller = await buildController(connection);
    addTearDown(controller.dispose);

    await controller.fetchReceiverLogs();

    expect(controller.statusIsError, isFalse, reason: controller.statusMessage);
    final List<File> saved = await receiverLogs(logDirectory);
    expect(saved, hasLength(1));
    expect(saved.single.readAsStringSync(), log);
    // Every chunk after the first must continue from the reported nextOffset.
    expect(connection.requestedOffsets, <int>[0, 12, 24, 36]);
  });

  test('rejects a retrieval whose totalBytes moves mid-fetch', () async {
    final List<Map<String, dynamic>> chunks = chunksOf('alpha\nbeta\n', 6);
    // A receiver re-reading a live buffer per chunk reports a drifting total;
    // that is the only signal the sender can use to notice a torn log.
    chunks[1] = <String, dynamic>{...chunks[1], 'totalBytes': 999};
    final _ScriptedConnection connection = _ScriptedConnection(chunks);
    final AppController controller = await buildController(connection);
    addTearDown(controller.dispose);

    await controller.fetchReceiverLogs();

    expect(controller.statusIsError, isTrue);
    expect(controller.statusMessage, contains('取回过程中发生变化'));
    expect(await receiverLogs(logDirectory), isEmpty);
  });

  test('restarts from offset 0 when the receiver snapshot expires', () async {
    const String log = 'alpha\nbeta\ngamma\n';
    final _ScriptedConnection connection = _ScriptedConnection(
      chunksOf(log, 6),
      expireAfter: 1,
    );
    final AppController controller = await buildController(connection);
    addTearDown(controller.dispose);

    await controller.fetchReceiverLogs();

    expect(controller.statusIsError, isFalse, reason: controller.statusMessage);
    expect(await receiverLogs(logDirectory), hasLength(1));
    // First chunk, then the expiring continuation, then a clean restart at 0.
    expect(connection.requestedOffsets.take(3), <int>[0, 6, 0]);
    expect((await receiverLogs(logDirectory)).single.readAsStringSync(), log);
  });

  test('a taken filename is suffixed rather than overwritten', () async {
    // Occupy the base name for this second AND the next, so the fetch is forced
    // down the suffix path regardless of which side of the boundary it lands
    // on. Keying off a single `now` would make this pass on a rollover without
    // ever exercising the loop.
    final DateTime now = DateTime.now();
    for (final DateTime when in <DateTime>[
      now,
      now.add(const Duration(seconds: 1)),
    ]) {
      File('${logDirectory.path}/receiver-${stampOf(when)}.log')
        ..createSync()
        ..writeAsStringSync('occupied');
    }

    final AppController controller = await buildController(
      _ScriptedConnection(chunksOf('fresh\n', 64)),
    );
    addTearDown(controller.dispose);
    await controller.fetchReceiverLogs();

    expect(controller.statusIsError, isFalse, reason: controller.statusMessage);
    final List<File> saved = await receiverLogs(logDirectory);
    final Iterable<File> suffixed = saved.where(
      (File file) => file.uri.pathSegments.last.endsWith('-1.log'),
    );
    expect(suffixed, hasLength(1));
    expect(suffixed.single.readAsStringSync(), 'fresh\n');
    // Neither occupied file was truncated.
    expect(
      saved.where((File f) => f.readAsStringSync() == 'occupied'),
      hasLength(2),
    );
  });

  test('retains only the newest three receiver logs', () async {
    // Pre-seed five stale files with distinct, ordered mtimes.
    final DateTime base = DateTime.now().subtract(const Duration(hours: 5));
    for (int index = 0; index < 5; index += 1) {
      final File stale = File('${logDirectory.path}/receiver-stale-$index.log')
        ..writeAsStringSync('stale $index');
      stale.setLastModifiedSync(base.add(Duration(hours: index)));
    }

    final AppController controller = await buildController(
      _ScriptedConnection(chunksOf('fresh\n', 64)),
    );
    addTearDown(controller.dispose);
    await controller.fetchReceiverLogs();

    final List<File> saved = await receiverLogs(logDirectory);
    expect(saved, hasLength(3));
    final Set<String> bodies = saved
        .map((File file) => file.readAsStringSync())
        .toSet();
    // The just-written file always survives, and the oldest go first.
    expect(bodies, contains('fresh\n'));
    expect(bodies, contains('stale 4'));
    expect(bodies, contains('stale 3'));
  });
}

class _ScriptedConnection extends CastConnection {
  _ScriptedConnection(this._chunks, {this.expireAfter})
    : super(
        senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        senderName: 'Test Sender',
      ) {
    sessionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  }

  final List<Map<String, dynamic>> _chunks;

  /// Reject the request at this index once with `invalid_state`, mimicking a
  /// receiver that released the frozen snapshot mid-retrieval.
  final int? expireAfter;

  final List<int> requestedOffsets = <int>[];
  int _served = 0;
  bool _expired = false;

  @override
  bool get isReady => true;

  @override
  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    if (type != 'diagnostics.logs.get') return <String, dynamic>{'ok': true};
    final int offset = payload['offset']! as int;
    requestedOffsets.add(offset);
    if (!_expired && expireAfter != null && _served == expireAfter) {
      _expired = true;
      _served += 1;
      throw ReceiverCommandRejected('invalid_state', 'snapshot expired');
    }
    _served += 1;
    return _chunks.firstWhere(
      (Map<String, dynamic> chunk) => chunk['offset'] == offset,
    );
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

class _FakeWebVideoResolver implements WebVideoResolver {
  @override
  void cancel() {}

  @override
  bool requiresExtraction(Uri uri) => false;

  @override
  Future<ResolvedWebVideo> resolve(Uri uri, {YtDlpBrowser? cookieBrowser}) =>
      throw UnimplementedError();
}
