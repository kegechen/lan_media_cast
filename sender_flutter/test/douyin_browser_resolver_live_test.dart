import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/douyin_browser_resolver.dart';

void main() {
  final String? liveUrl = Platform.environment['LAN_MEDIA_CAST_DOUYIN_URL'];
  final bool headful =
      Platform.environment['LAN_MEDIA_CAST_DOUYIN_HEADFUL'] == 'true';
  final bool requireCombined =
      Platform.environment['LAN_MEDIA_CAST_DOUYIN_REQUIRE_COMBINED'] == 'true';

  test(
    'Edge resolves live Douyin video and audio tracks',
    () async {
      final EdgeDouyinBrowserResolver resolver = EdgeDouyinBrowserResolver(
        headless: !headful,
      );
      addTearDown(resolver.cancel);

      final DouyinBrowserResult result = await resolver.resolve(
        Uri.parse(liveUrl!),
      );
      if (requireCombined) {
        expect(result.audioUrl, isNull);
      }

      expect(result.videoUrl.scheme, 'https');
      expect(isTrustedDouyinMediaUri(result.videoUrl), isTrue);
      expect(
        result.videoUrl.path,
        anyOf(contains('media-video-avc1'), contains('/video/tos/')),
      );
      expect(result.videoContentLength, greaterThan(0));
      final List<Map<String, String>> videoTracks = await _probeTracks(
        result.videoUrl,
        result.httpHeaders,
      );
      expect(
        videoTracks,
        contains(
          predicate<Map<String, String>>(
            (Map<String, String> track) =>
                track['codec_type'] == 'video' && track['codec_name'] == 'h264',
          ),
        ),
      );
      if (result.audioUrl case final Uri audioUrl) {
        expect(audioUrl.scheme, 'https');
        expect(isTrustedDouyinMediaUri(audioUrl), isTrue);
        expect(audioUrl.path, contains('media-audio-'));
        expect(result.audioContentLength, greaterThan(0));
        expect(
          await _probeTracks(audioUrl, result.httpHeaders),
          contains(
            predicate<Map<String, String>>(
              (Map<String, String> track) =>
                  track['codec_type'] == 'audio' &&
                  track['codec_name'] == 'aac',
            ),
          ),
        );
      } else {
        expect(
          videoTracks,
          contains(
            predicate<Map<String, String>>(
              (Map<String, String> track) =>
                  track['codec_type'] == 'audio' &&
                  track['codec_name'] == 'aac',
            ),
          ),
        );
      }
      expect(result.title, isNotEmpty);
      expect(result.httpHeaders, isNot(contains('Cookie')));
    },
    skip: liveUrl == null
        ? 'Set LAN_MEDIA_CAST_DOUYIN_URL to run the live Edge test.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<List<Map<String, String>>> _probeTracks(
  Uri uri,
  Map<String, String> headers,
) async {
  final Process process = await Process.start('ffprobe', <String>[
    '-v',
    'error',
    '-rw_timeout',
    '10000000',
    '-user_agent',
    headers['User-Agent'] ?? '',
    '-referer',
    headers['Referer'] ?? '',
    '-show_entries',
    'stream=codec_type,codec_name',
    '-of',
    'json',
    uri.toString(),
  ], runInShell: false);
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 30));
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    throw TimeoutException('ffprobe did not finish in time');
  }
  final String output = await stdout;
  final String diagnostic = await stderr;
  if (exitCode != 0) {
    throw ProcessException('ffprobe', const <String>[], diagnostic, exitCode);
  }
  final Map<String, dynamic> metadata = (jsonDecode(output) as Map)
      .cast<String, dynamic>();
  return (metadata['streams'] as List<dynamic>)
      .whereType<Map<dynamic, dynamic>>()
      .map(
        (Map<dynamic, dynamic> stream) => <String, String>{
          'codec_type': stream['codec_type'] as String? ?? '',
          'codec_name': stream['codec_name'] as String? ?? '',
        },
      )
      .toList();
}
