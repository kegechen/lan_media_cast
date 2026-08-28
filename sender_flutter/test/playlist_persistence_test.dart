import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('playlist revision advances beyond receiver state', () {
    expect(nextPlaylistRevision(3, 12), 13);
    expect(nextPlaylistRevision(20, 12), 21);
  });

  test('plain HTTP inputs and split tracks remain visibly insecure', () {
    expect(isInsecureHttpInput(' http://media.example/video.mp4 '), isTrue);
    expect(isInsecureHttpInput('https://media.example/video.mp4'), isFalse);
    expect(
      isInsecureHttpInput('复制后打开 http://media.example/video.mp4 看视频'),
      isTrue,
    );
    expect(
      isInsecureRemoteSource(
        const SenderPlaylistItem(
          id: '33333333-3333-4333-8333-333333333333',
          name: 'lesson',
          source: <String, Object>{
            'kind': 'url',
            'url': 'https://media.example/video.mp4',
            'audioTrack': <String, Object>{
              'url': 'http://media.example/audio.m4a',
            },
          },
        ),
      ),
      isTrue,
    );
  });

  test('extracts a network URL from shared text', () {
    const String douyinShareText =
        '2.84 复制打开抖音，看看【luffy君的作品】“你多久没看海贼王了” '
        '# 夏日夜话季 https://v.douyin.com/m7yCsqVUEtQ/ e@O.Kw mqr:/ 03/01';

    expect(
      parseNetworkMediaInput(douyinShareText)?.toString(),
      'https://v.douyin.com/m7yCsqVUEtQ/',
    );
    expect(
      parseNetworkMediaInput(
        '媒体地址：https://media.example/video.mp4。',
      )?.toString(),
      'https://media.example/video.mp4',
    );
    expect(
      parseNetworkMediaInput('rtsp://camera.example/live')?.toString(),
      'rtsp://camera.example/live',
    );
    expect(parseNetworkMediaInput('没有可用的网络地址'), isNull);
  });

  test('webpage refresh metadata stays on the sender', () {
    final SenderPlaylistItem item = SenderPlaylistItem(
      id: '33333333-3333-4333-8333-333333333333',
      name: 'lesson',
      source: <String, Object>{
        'kind': 'url',
        'name': 'lesson',
        'url': 'https://cdn.example/lesson-video.mp4?token=temporary',
        'webpageUrl': 'https://video.example/watch/lesson',
        'resolvedAt': 1787800000000,
        'cookieBrowser': 'edge',
        'cacheKey': 'web:lesson:primary',
        'httpHeaders': <String, String>{'Referer': 'https://video.example/'},
        'audioTrack': <String, Object>{
          'url': 'https://cdn.example/lesson-audio.m4a?token=temporary',
          'cacheKey': 'web:lesson:audio',
          'httpHeaders': <String, String>{'Referer': 'https://video.example/'},
        },
      },
    );

    final Map<String, Object> source = protocolSourceForItem(item);

    expect(source, isNot(contains('webpageUrl')));
    expect(source, isNot(contains('resolvedAt')));
    expect(source, isNot(contains('cookieBrowser')));
    expect(source['url'], contains('token=temporary'));
    expect(source['cacheKey'], 'web:lesson:primary');
    expect(source['audioTrack'], isA<Map<String, Object>>());
    expect(source['httpHeaders'], <String, String>{
      'Referer': 'https://video.example/',
    });
  });

  test(
    'restores playlist order and retains an unavailable local file',
    () async {
      final Directory temporaryDirectory = await Directory.systemTemp
          .createTemp('lan-media-playlist-test-');
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final File available = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}available.mp4',
      );
      await available.writeAsBytes(
        List<int>.generate(64, (int index) => index),
      );
      final String missing =
          '${temporaryDirectory.path}${Platform.pathSeparator}missing.mp4';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sender_id': 'e5cb742f-1fb5-4558-a8d8-5113035101e2',
        'playlist_v1': jsonEncode(<String, Object>{
          'revision': 7,
          'repeatMode': 'repeatAll',
          'items': <Map<String, Object?>>[
            <String, Object?>{
              'id': '11111111-1111-4111-8111-111111111111',
              'name': 'available.mp4',
              'kind': 'local',
              'path': available.path,
            },
            <String, Object?>{
              'id': '22222222-2222-4222-8222-222222222222',
              'name': 'missing.mp4',
              'kind': 'local',
              'path': missing,
            },
            <String, Object?>{
              'id': '33333333-3333-4333-8333-333333333333',
              'name': 'stream.mp4',
              'kind': 'url',
              'url': 'https://media.example/stream.mp4',
              'webpageUrl': 'https://video.example/watch/lesson',
              'resolvedAt': 1787800000000,
              'cookieBrowser': 'edge',
              'cacheKey': 'web:lesson:primary',
              'httpHeaders': <String, String>{
                'User-Agent': 'LAN Media Cast test',
                'Referer': 'https://video.example/',
              },
              'audioTrack': <String, Object>{
                'url': 'https://media.example/audio.m4a',
                'cacheKey': 'web:lesson:audio',
              },
            },
            <String, Object?>{
              'id': '44444444-4444-4444-8444-444444444444',
              'name': 'single-stream.m3u8',
              'kind': 'url',
              'url': 'https://media.example/single-stream.m3u8',
              'formatHint': 'hls',
            },
          ],
        }),
      });
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      final AppController controller = await AppController.create();
      addTearDown(controller.dispose);

      expect(controller.repeatMode, 'repeatAll');
      expect(
        controller.playlist.map((SenderPlaylistItem item) => item.name),
        <String>[
          'available.mp4',
          'missing.mp4',
          'stream.mp4',
          'single-stream.m3u8',
        ],
      );
      expect(controller.playlist[0].isAvailable, isTrue);
      expect(controller.playlist[0].localAsset, isNotNull);
      expect(controller.playlist[1].isAvailable, isFalse);
      expect(controller.playlist[1].unavailableReason, '文件不可用');
      expect(controller.playlist[2].source['formatHint'], isNull);
      expect(
        controller.playlist[2].source['webpageUrl'],
        'https://video.example/watch/lesson',
      );
      expect(controller.playlist[2].source['resolvedAt'], 1787800000000);
      expect(controller.playlist[2].source['cookieBrowser'], 'edge');
      expect(controller.playlist[2].source['cacheKey'], 'web:lesson:primary');
      expect(
        (controller.playlist[2].source['audioTrack']
            as Map<String, Object>)['cacheKey'],
        'web:lesson:audio',
      );
      expect(controller.playlist[2].source['httpHeaders'], <String, String>{
        'User-Agent': 'LAN Media Cast test',
        'Referer': 'https://video.example/',
      });
      expect(controller.playlist[3].source['formatHint'], 'hls');
      expect(controller.playlist[3].source['audioTrack'], isNull);
    },
  );

  test(
    'rejects a persisted adaptive primary with a separate audio track',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sender_id': 'e5cb742f-1fb5-4558-a8d8-5113035101e2',
        'playlist_v1': jsonEncode(<String, Object>{
          'revision': 7,
          'repeatMode': 'repeatAll',
          'items': <Map<String, Object?>>[
            <String, Object?>{
              'id': '33333333-3333-4333-8333-333333333333',
              'name': 'invalid-split.m3u8',
              'kind': 'url',
              'url': 'https://media.example/invalid-split.m3u8',
              'formatHint': 'hls',
              'audioTrack': <String, Object>{
                'url': 'https://media.example/audio.m4a',
              },
            },
          ],
        }),
      });
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      final AppController controller = await AppController.create();
      addTearDown(controller.dispose);
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();

      expect(controller.playlist, isEmpty);
      expect(controller.repeatMode, 'playOnce');
      expect(preferences.getString('playlist_v1'), isNull);
    },
  );
}
