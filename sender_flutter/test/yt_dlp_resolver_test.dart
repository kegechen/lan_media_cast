import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/douyin_browser_resolver.dart';
import 'package:lan_media_cast_sender/services/windows_system_proxy.dart';
import 'package:lan_media_cast_sender/services/yt_dlp_resolver.dart';

void main() {
  test('direct media URL bypasses yt-dlp', () async {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(exitCode: 99, stdout: '', stderr: ''),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
    );

    final ResolvedWebVideo result = await resolver.resolve(
      Uri.parse('https://media.example/video.mp4?token=temporary'),
    );

    expect(result.url.path, '/video.mp4');
    expect(result.extracted, isFalse);
    expect(runner.calls, 0);
  });

  test('webpage metadata becomes a safe remote media source', () async {
    final _FakeRunner runner = _FakeRunner(
      YtDlpProcessResult(
        exitCode: 0,
        stdout: jsonEncode(<String, Object>{
          'title': 'Example lesson',
          'webpage_url': 'https://video.example/watch/1',
          'url': 'https://cdn.example/master.m3u8?token=short-lived',
          'protocol': 'm3u8_native',
          'ext': 'mp4',
          'http_headers': <String, Object>{
            'User-Agent': 'yt-dlp test',
            'Referer': 'https://video.example/',
            'Cookie': 'must-not-leave-the-sender',
            'Authorization': 'must-not-leave-the-sender',
          },
        }),
        stderr: '',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'C:\\tools\\yt-dlp.exe',
      isWindows: true,
    );

    final ResolvedWebVideo result = await resolver.resolve(
      Uri.parse('https://video.example/watch/1'),
    );

    expect(result.name, 'Example lesson');
    expect(result.formatHint, 'hls');
    expect(result.webpageUrl.toString(), 'https://video.example/watch/1');
    expect(result.resolvedAt, isNotNull);
    expect(result.httpHeaders, <String, String>{
      'User-Agent': 'yt-dlp test',
      'Referer': 'https://video.example/',
    });
    expect(
      runner.arguments,
      containsAll(<String>['--ignore-config', '--no-playlist']),
    );
    expect(runner.arguments.last, 'https://video.example/watch/1');
  });

  test('separate audio and video formats are preserved', () async {
    final _FakeRunner runner = _FakeRunner(
      YtDlpProcessResult(
        exitCode: 0,
        stdout: jsonEncode(<String, Object>{
          'title': 'Split lesson',
          'http_headers': <String, String>{'Referer': 'https://video.example/'},
          'requested_formats': <Object>[
            <String, Object>{
              'format_id': 'v',
              'url': 'https://cdn.example/video-only.mp4',
              'protocol': 'https',
              'vcodec': 'avc1.640028',
              'acodec': 'none',
            },
            <String, Object>{
              'format_id': 'a',
              'url': 'https://cdn.example/audio-only.m4a',
              'protocol': 'https',
              'vcodec': 'none',
              'acodec': 'mp4a.40.2',
              'http_headers': <String, String>{'User-Agent': 'audio-agent'},
            },
          ],
        }),
        stderr: '',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
    );

    final ResolvedWebVideo result = await resolver.resolve(
      Uri.parse('https://video.example/watch/2'),
    );

    expect(result.url.toString(), 'https://cdn.example/video-only.mp4');
    expect(result.httpHeaders, <String, String>{
      'Referer': 'https://video.example/',
    });
    expect(
      result.audioTrack?.url.toString(),
      'https://cdn.example/audio-only.m4a',
    );
    expect(result.audioTrack?.httpHeaders, <String, String>{
      'User-Agent': 'audio-agent',
    });
    expect(
      runner.arguments[runner.arguments.indexOf('--format') + 1],
      contains('+'),
    );
  });

  test('browser cookies are opt-in and remain inside yt-dlp', () async {
    final _FakeRunner runner = _FakeRunner(
      YtDlpProcessResult(
        exitCode: 0,
        stdout: jsonEncode(<String, Object>{
          'url': 'https://cdn.example/video.mp4',
          'protocol': 'https',
          'http_headers': <String, String>{
            'Cookie': 'session=secret',
            'Referer': 'https://video.example/',
          },
        }),
        stderr: '',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
    );

    final ResolvedWebVideo result = await resolver.resolve(
      Uri.parse('https://video.example/watch/private'),
      cookieBrowser: YtDlpBrowser.edge,
    );

    expect(
      runner.arguments,
      containsAllInOrder(<String>['--cookies-from-browser', 'edge']),
    );
    expect(result.cookieBrowser, YtDlpBrowser.edge);
    expect(result.httpHeaders, <String, String>{
      'Referer': 'https://video.example/',
    });
  });

  test('yt-dlp failures preserve a bounded sanitized diagnostic', () async {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr:
            'WARNING: preliminary failure\n'
            'ERROR: request failed at https://cdn.example/video?id=secret '
            'using "C:\\Users\\private-user\\AppData\\Local\\Edge\\Cookies"; '
            'Authorization: Bearer top-secret',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
    );

    await expectLater(
      resolver.resolve(Uri.parse('https://video.example/watch/failed')),
      throwsA(
        isA<YtDlpException>()
            .having(
              (YtDlpException error) => error.message,
              'message',
              contains('详情：ERROR: request failed at <URL>'),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('top-secret')),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('private-user')),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              contains('<PATH>'),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('cdn.example')),
            ),
      ),
    );
  });

  test('yt-dlp diagnostics redact complete cookie headers', () async {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Cookie: sid=first-secret; auth=second-secret',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
    );

    await expectLater(
      resolver.resolve(Uri.parse('https://video.example/watch/private')),
      throwsA(
        isA<YtDlpException>()
            .having(
              (YtDlpException error) => error.message,
              'message',
              contains('Cookie=<redacted>'),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('first-secret')),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('second-secret')),
            ),
      ),
    );
  });

  test('Douyin failure falls back to Edge media tracks', () async {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Fresh cookies are needed',
      ),
    );
    final _FakeDouyinResolver douyinResolver = _FakeDouyinResolver(
      DouyinBrowserResult(
        videoUrl: Uri(
          scheme: 'https',
          host: 'v26-web.douyinvod.com',
          path: '/media-video-avc1/',
        ),
        audioUrl: Uri(
          scheme: 'https',
          host: 'v26-web.douyinvod.com',
          path: '/media-audio-und-mp4a/',
        ),
        title: 'Example Douyin video',
        videoContentLength: 70000000,
        audioContentLength: 11000000,
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      douyinBrowserResolver: douyinResolver,
      isWindows: true,
    );

    final ResolvedWebVideo result = await resolver.resolve(
      Uri.parse('https://v.douyin.com/example/'),
    );

    expect(douyinResolver.calls, 1);
    expect(result.name, 'Example Douyin video');
    expect(result.primaryTrack.formatId, 'douyin-browser-video');
    expect(result.primaryTrack.contentLength, 70000000);
    expect(result.audioTrack?.formatId, 'douyin-browser-audio');
    expect(result.audioTrack?.contentLength, 11000000);
    expect(result.httpHeaders['Cookie'], isNull);
    expect(result.httpHeaders['Referer'], 'https://www.douyin.com/');
  });

  test('Douyin fallback failure keeps a sanitized yt-dlp diagnostic', () async {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr:
            'ERROR: request to https://www.douyin.com/private failed; '
            'Cookie: sid=secret',
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      douyinBrowserResolver: _FailingDouyinResolver(),
      isWindows: true,
    );

    await expectLater(
      resolver.resolve(Uri.parse('https://v.douyin.com/example/')),
      throwsA(
        isA<YtDlpException>()
            .having(
              (YtDlpException error) => error.message,
              'message',
              contains('抖音页面解析失败：等待抖音视频地址超时'),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              contains('<URL>'),
            )
            .having(
              (YtDlpException error) => error.message,
              'message',
              isNot(contains('secret')),
            ),
      ),
    );
  });

  test('cancel reaches both yt-dlp and Douyin fallback', () {
    final _FakeRunner runner = _FakeRunner(
      const YtDlpProcessResult(exitCode: 1, stdout: '', stderr: ''),
    );
    final _FakeDouyinResolver douyinResolver = _FakeDouyinResolver(
      DouyinBrowserResult(
        videoUrl: Uri(scheme: 'https', host: 'example.com'),
        title: 'unused',
        videoContentLength: null,
      ),
    );
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      douyinBrowserResolver: douyinResolver,
      isWindows: true,
    );

    resolver.cancel();

    expect(runner.cancelled, isTrue);
    expect(douyinResolver.cancelled, isTrue);
  });

  test('bounded process runner stops a timed out process', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'yt-dlp-runner-timeout-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final File script = File(
      '${temporary.path}${Platform.pathSeparator}wait.dart',
    );
    await script.writeAsString(
      "Future<void> main() => Future<void>.delayed(const Duration(seconds: 5));",
    );
    final BoundedYtDlpProcessRunner runner = BoundedYtDlpProcessRunner();

    await expectLater(
      runner.run(
        _dartExecutable(),
        <String>[script.path],
        timeout: const Duration(milliseconds: 200),
        maxStdoutBytes: 1024,
        maxStderrBytes: 1024,
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('bounded process runner rejects oversized output', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'yt-dlp-runner-output-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final File script = File(
      '${temporary.path}${Platform.pathSeparator}output.dart',
    );
    await script.writeAsString(
      "import 'dart:io'; void main() { stdout.write(List.filled(2048, 'x').join()); }",
    );
    final BoundedYtDlpProcessRunner runner = BoundedYtDlpProcessRunner();

    await expectLater(
      runner.run(
        _dartExecutable(),
        <String>[script.path],
        timeout: const Duration(seconds: 10),
        maxStdoutBytes: 128,
        maxStderrBytes: 1024,
      ),
      throwsA(isA<YtDlpException>()),
    );
  });

  test('bounded process runner cancels the active process', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'yt-dlp-runner-cancel-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final File script = File(
      '${temporary.path}${Platform.pathSeparator}wait.dart',
    );
    await script.writeAsString(
      "Future<void> main() => Future<void>.delayed(const Duration(seconds: 5));",
    );
    final BoundedYtDlpProcessRunner runner = BoundedYtDlpProcessRunner();

    final Future<YtDlpProcessResult> running = runner.run(
      _dartExecutable(),
      <String>[script.path],
      timeout: const Duration(seconds: 10),
      maxStdoutBytes: 1024,
      maxStderrBytes: 1024,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    runner.cancel();

    await expectLater(running, throwsA(isA<YtDlpException>()));
  });

  _cookieFallbackTests();
}

YtDlpResolver _resolverWith(YtDlpProcessRunner runner) => YtDlpResolver(
  processRunner: runner,
  executableLocator: () => 'yt-dlp.exe',
  isWindows: true,
  environment: () => const <String, String>{},
  systemProxyReader: () async => null,
);

String _successPayload() => jsonEncode(<String, Object>{
  'title': 'Example lesson',
  'webpage_url': 'https://video.example/watch/1',
  'url': 'https://cdn.example/video.mp4',
  'protocol': 'https',
  'ext': 'mp4',
  'http_headers': <String, Object>{'User-Agent': 'yt-dlp test'},
});

void _cookieFallbackTests() {
  test('unreadable browser cookies fall back to an anonymous retry', () async {
    // Chrome/Edge 127+ encrypt their cookie store so it cannot be read from
    // outside the browser. Cookies are optional for most pages, so this must
    // degrade rather than fail the whole resolution.
    final _ScriptedRunner runner = _ScriptedRunner(<YtDlpProcessResult>[
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Failed to decrypt with DPAPI. See https://... for info',
      ),
      YtDlpProcessResult(exitCode: 0, stdout: _successPayload(), stderr: ''),
    ]);

    final ResolvedWebVideo result = await _resolverWith(runner).resolve(
      Uri.parse('https://video.example/watch/1'),
      cookieBrowser: YtDlpBrowser.chrome,
    );

    expect(runner.calls, 2);
    expect(runner.invocations.first, contains('--cookies-from-browser'));
    expect(runner.invocations.last, isNot(contains('--cookies-from-browser')));
    expect(result.notice, contains('未能读取'));
    // The stored source must not keep pointing at a cookie store that failed.
    expect(result.cookieBrowser, isNull);
  });

  test('a page that truly needs login still reports that', () async {
    final _ScriptedRunner runner = _ScriptedRunner(<YtDlpProcessResult>[
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Failed to decrypt with DPAPI.',
      ),
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: "ERROR: Sign in to confirm you're not a bot.",
      ),
    ]);

    await expectLater(
      _resolverWith(runner).resolve(
        Uri.parse('https://video.example/watch/1'),
        cookieBrowser: YtDlpBrowser.chrome,
      ),
      throwsA(
        isA<YtDlpException>().having(
          (YtDlpException error) => error.message,
          'message',
          contains('需要登录'),
        ),
      ),
    );
    expect(runner.calls, 2);
  });

  test('a failed retry reports its own error, not the cookie one', () async {
    // The diagnostic sanitizer keeps only the last "error:" line, so appending
    // the cookie failure used to overwrite the retry's real reason and blame
    // the cookie store for an unrelated network fault.
    final _ScriptedRunner runner = _ScriptedRunner(<YtDlpProcessResult>[
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Failed to decrypt with DPAPI.',
      ),
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Unable to download webpage: HTTP Error 412',
      ),
    ]);

    await expectLater(
      _resolverWith(runner).resolve(
        Uri.parse('https://video.example/watch/1'),
        cookieBrowser: YtDlpBrowser.chrome,
      ),
      throwsA(
        isA<YtDlpException>()
            .having(
              (YtDlpException error) => error.message,
              'keeps the retry error',
              contains('HTTP Error 412'),
            )
            .having(
              (YtDlpException error) => error.message,
              'still mentions the cookie failure',
              contains('DPAPI'),
            ),
      ),
    );
  });

  test('a non-cookie failure is not retried', () async {
    final _ScriptedRunner runner = _ScriptedRunner(<YtDlpProcessResult>[
      const YtDlpProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ERROR: Unsupported URL: https://video.example/watch/1',
      ),
    ]);

    await expectLater(
      _resolverWith(runner).resolve(
        Uri.parse('https://video.example/watch/1'),
        cookieBrowser: YtDlpBrowser.chrome,
      ),
      throwsA(isA<YtDlpException>()),
    );
    expect(runner.calls, 1);
  });

  test('the system proxy reaches the yt-dlp process', () async {
    final _ScriptedRunner runner = _ScriptedRunner(<YtDlpProcessResult>[
      YtDlpProcessResult(exitCode: 0, stdout: _successPayload(), stderr: ''),
    ]);
    final YtDlpResolver resolver = YtDlpResolver(
      processRunner: runner,
      executableLocator: () => 'yt-dlp.exe',
      isWindows: true,
      environment: () => const <String, String>{'NO_PROXY': 'corp.example'},
      systemProxyReader: () async =>
          const WindowsSystemProxy(
            httpServer: 'http://127.0.0.1:10808',
            httpsServer: 'http://127.0.0.1:10808',
          ),
    );

    await resolver.resolve(Uri.parse('https://video.example/watch/1'));

    expect(runner.environments.single['HTTPS_PROXY'], 'http://127.0.0.1:10808');
  });
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) return 'dart';
  final String executable = Platform.isWindows ? 'dart.exe' : 'dart';
  return '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}$executable';
}

/// Returns a different result per call, so a retry can be observed.
class _ScriptedRunner implements YtDlpProcessRunner {
  _ScriptedRunner(this._results);

  final List<YtDlpProcessResult> _results;
  final List<List<String>> invocations = <List<String>>[];
  final List<Map<String, String>> environments = <Map<String, String>>[];

  int get calls => invocations.length;

  @override
  Future<YtDlpProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    Map<String, String> environment = const <String, String>{},
  }) async {
    invocations.add(arguments);
    environments.add(environment);
    return _results[invocations.length - 1];
  }

  @override
  void cancel() {}
}

class _FakeRunner implements YtDlpProcessRunner {
  _FakeRunner(this.result);

  final YtDlpProcessResult result;
  int calls = 0;
  bool cancelled = false;
  List<String> arguments = <String>[];
  Map<String, String> environment = const <String, String>{};

  @override
  Future<YtDlpProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    Map<String, String> environment = const <String, String>{},
  }) async {
    calls += 1;
    this.arguments = arguments;
    this.environment = environment;
    return result;
  }

  @override
  void cancel() => cancelled = true;
}

class _FakeDouyinResolver implements DouyinBrowserResolver {
  _FakeDouyinResolver(this.result);

  final DouyinBrowserResult result;
  int calls = 0;
  bool cancelled = false;

  @override
  Future<DouyinBrowserResult> resolve(Uri uri) async {
    calls += 1;
    return result;
  }

  @override
  void cancel() => cancelled = true;
}

class _FailingDouyinResolver implements DouyinBrowserResolver {
  @override
  Future<DouyinBrowserResult> resolve(Uri uri) {
    throw const DouyinBrowserException('等待抖音视频地址超时');
  }

  @override
  void cancel() {}
}
