import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/douyin_browser_resolver.dart';

void main() {
  test('Douyin page allowlist accepts only Douyin HTTP(S) hosts', () {
    expect(isDouyinPageUri(Uri.parse('https://v.douyin.com/abc/')), isTrue);
    expect(
      isDouyinPageUri(Uri.parse('https://www.iesdouyin.com/share/video/1/')),
      isTrue,
    );
    expect(isDouyinPageUri(Uri.parse('http://www.douyin.com/video/1')), isTrue);
    expect(
      isDouyinPageUri(Uri.parse('https://douyin.com.attacker.example/video')),
      isFalse,
    );
    expect(isDouyinPageUri(Uri.parse('file:///douyin.com/video/1')), isFalse);
  });

  test(
    'Douyin media allowlist rejects lookalikes, HTTP, and oversized URLs',
    () {
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse('https://v26-web.douyinvod.com/video/tos/example'),
        ),
        isTrue,
      );
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse('https://v5-default.365yg.com/video/tos/example'),
        ),
        isTrue,
      );
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse('https://evil-douyinvod.com.attacker.example/video.mp4'),
        ),
        isFalse,
      );
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse('https://365yg.com.attacker.example/video.mp4'),
        ),
        isFalse,
      );
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse('http://v26-web.douyinvod.com/video.mp4'),
        ),
        isFalse,
      );
      expect(
        isTrustedDouyinMediaUri(
          Uri.parse(
            'https://v26-web.douyinvod.com/video.mp4?q='
            '${List<String>.filled(4096, 'x').join()}',
          ),
        ),
        isFalse,
      );
    },
  );

  test('snapshot keeps API H264 and self-describing split tracks separate', () {
    final String apiVideo =
        'https://v26-web.douyinvod.com/video/tos/example'
        '?mime_type=video_mp4';
    final String api365Video =
        'https://v5-default.365yg.com/video/tos/example-h264';
    final String splitVideo = 'https://v26-web.douyinvod.com/media-video-avc1/';
    final String splitAudio =
        'https://v26-web.douyinvod.com/media-audio-und-mp4a/';
    final String unknownPerformanceVideo =
        'https://v26-web.douyinvod.com/video/tos/unknown-codec'
        '?mime_type=video_mp4';
    final DouyinBrowserSnapshot snapshot = DouyinBrowserSnapshot.fromEvaluation(
      <String, dynamic>{
        'result': <String, dynamic>{
          'value': jsonEncode(<String, Object>{
            'href': 'https://www.douyin.com/video/1',
            'title': 'Example - 抖音',
            'apiResources': <String>[
              apiVideo,
              api365Video,
              'https://douyinvod.com.attacker.example/video/tos/bad',
            ],
            'performanceResources': <String>[
              splitVideo,
              splitAudio,
              unknownPerformanceVideo,
            ],
            'challengeVisible': false,
          }),
        },
      },
    );

    expect(snapshot.title, 'Example');
    expect(
      snapshot.combinedCandidates.map((Uri uri) => uri.toString()),
      <String>[apiVideo, api365Video],
    );
    expect(snapshot.videoCandidates.single.toString(), splitVideo);
    expect(snapshot.audioCandidates.single.toString(), splitAudio);
    expect(
      snapshot.combinedCandidates,
      isNot(contains(Uri.parse(unknownPerformanceVideo))),
    );
  });

  test('snapshot rejects malformed evaluation data', () {
    expect(
      () => DouyinBrowserSnapshot.fromEvaluation(<String, dynamic>{
        'result': <String, dynamic>{'value': 'not-json'},
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DouyinBrowserSnapshot.fromEvaluation(<String, dynamic>{}),
      throwsA(isA<DouyinBrowserException>()),
    );
  });

  test('Content-Range total parser is strict', () {
    expect(parseDouyinContentRangeTotal('bytes 0-0/71271403'), 71271403);
    expect(parseDouyinContentRangeTotal('bytes */71271403'), isNull);
    expect(parseDouyinContentRangeTotal('0-0/71271403'), isNull);
    expect(parseDouyinContentRangeTotal(null), isNull);
  });

  test(
    'concurrent resolve is rejected and temporary profile is removed',
    () async {
      final Set<String> profilesBefore = await _temporaryProfiles();
      final EdgeDouyinBrowserResolver resolver = EdgeDouyinBrowserResolver(
        executableLocator: _dartExecutable,
        pageLoadTimeout: const Duration(seconds: 1),
      );

      final Future<DouyinBrowserResult> first = resolver.resolve(
        Uri.parse('https://www.douyin.com/video/1'),
      );
      await expectLater(
        resolver.resolve(Uri.parse('https://www.douyin.com/video/2')),
        throwsA(
          isA<DouyinBrowserException>().having(
            (DouyinBrowserException error) => error.message,
            'message',
            contains('已有抖音页面正在解析'),
          ),
        ),
      );

      await _waitForNewTemporaryProfile(profilesBefore);
      resolver.cancel();
      await expectLater(first, throwsA(isA<DouyinBrowserException>()));

      final Set<String> profilesAfter = await _temporaryProfiles();
      expect(profilesAfter.difference(profilesBefore), isEmpty);
    },
  );
}

Future<Set<String>> _temporaryProfiles() async {
  final Set<String> paths = <String>{};
  await for (final FileSystemEntity entity in Directory.systemTemp.list(
    followLinks: false,
  )) {
    if (entity is Directory &&
        entity.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('lan-media-cast-douyin-')) {
      paths.add(entity.path);
    }
  }
  return paths;
}

Future<void> _waitForNewTemporaryProfile(Set<String> existing) async {
  for (int attempt = 0; attempt < 50; attempt++) {
    if ((await _temporaryProfiles()).difference(existing).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('temporary Edge profile was not created');
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) return 'dart';
  final String executable = Platform.isWindows ? 'dart.exe' : 'dart';
  return '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}$executable';
}
