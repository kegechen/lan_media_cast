import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/app_log.dart';

void main() {
  test('rotates bounded log files', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'lan-media-log-rotation-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final AppLog log = AppLog(maxFileBytes: 400, retainedFileCount: 3);
    await log.initialize(directory: directory);

    for (int index = 0; index < 20; index++) {
      await log.info(
        'rotation.test',
        fields: <String, Object?>{'index': index, 'payload': 'x' * 80},
      );
    }
    await log.flush();

    final List<File> files = directory
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.log'))
        .toList();
    expect(files, hasLength(3));
    expect(
      File('${directory.path}${Platform.pathSeparator}sender.log').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${directory.path}${Platform.pathSeparator}sender.1.log',
      ).existsSync(),
      isTrue,
    );
    expect(
      await File(
        '${directory.path}${Platform.pathSeparator}sender.log',
      ).readAsString(),
      contains('"index":19'),
    );
  });

  test('redacts credentials and signed URLs', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'lan-media-log-redaction-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final AppLog log = AppLog();
    await log.initialize(directory: directory);

    await log.error(
      'redaction.test',
      StateError(
        'GET https://cdn.example/video.mp4?token=secret failed; '
        'Bearer bearer-secret',
      ),
      fields: <String, Object?>{
        'bearerToken': 'field-secret',
        'cookie': 'session=secret',
      },
    );
    await log.flush();

    final String contents = await File(
      '${directory.path}${Platform.pathSeparator}sender.log',
    ).readAsString();
    expect(contents, contains('[REDACTED]'));
    expect(contents, contains('https://cdn.example/[REDACTED]'));
    expect(contents, isNot(contains('secret')));
    expect(contents, isNot(contains('video.mp4')));
  });
}
