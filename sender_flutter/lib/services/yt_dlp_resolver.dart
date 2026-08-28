import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/remote_http_headers.dart';
import 'douyin_browser_resolver.dart';

const Duration defaultYtDlpTimeout = Duration(seconds: 45);
const int defaultYtDlpStdoutLimit = 8 * 1024 * 1024;
const int defaultYtDlpStderrLimit = 256 * 1024;

abstract interface class WebVideoResolver {
  bool requiresExtraction(Uri uri);

  Future<ResolvedWebVideo> resolve(Uri uri, {YtDlpBrowser? cookieBrowser});

  void cancel();
}

enum YtDlpBrowser {
  edge,
  chrome,
  firefox;

  static YtDlpBrowser? fromName(String? value) {
    for (final YtDlpBrowser browser in values) {
      if (browser.name == value) return browser;
    }
    return null;
  }
}

class ResolvedWebVideoTrack {
  const ResolvedWebVideoTrack({
    required this.url,
    required this.httpHeaders,
    this.formatHint,
    this.formatId,
    this.contentLength,
  });

  final Uri url;
  final String? formatHint;
  final String? formatId;
  final int? contentLength;
  final Map<String, String> httpHeaders;
}

class ResolvedWebVideo {
  const ResolvedWebVideo({
    required this.primaryTrack,
    required this.name,
    this.audioTrack,
    this.webpageUrl,
    this.resolvedAt,
    this.cookieBrowser,
  });

  final ResolvedWebVideoTrack primaryTrack;
  final ResolvedWebVideoTrack? audioTrack;
  final String name;
  final Uri? webpageUrl;
  final int? resolvedAt;
  final YtDlpBrowser? cookieBrowser;

  Uri get url => primaryTrack.url;
  String? get formatHint => primaryTrack.formatHint;
  Map<String, String> get httpHeaders => primaryTrack.httpHeaders;

  bool get extracted => webpageUrl != null;
}

class YtDlpProcessResult {
  const YtDlpProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class YtDlpProcessRunner {
  Future<YtDlpProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
  });

  void cancel();
}

class BoundedYtDlpProcessRunner implements YtDlpProcessRunner {
  Process? _activeProcess;
  bool _startPending = false;
  bool _cancelRequested = false;

  @override
  Future<YtDlpProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
  }) async {
    if (_activeProcess != null || _startPending) {
      throw const YtDlpException('已有网页视频正在解析，请稍候');
    }
    _cancelRequested = false;
    _startPending = true;
    final Process process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
    } finally {
      _startPending = false;
    }
    _activeProcess = process;
    if (_cancelRequested) process.kill();
    try {
      final List<dynamic> completed =
          await Future.wait<dynamic>(<Future<dynamic>>[
            process.exitCode,
            _readBounded(
              process.stdout,
              maxStdoutBytes,
              'yt-dlp 标准输出超过限制',
              process,
            ),
            _readBounded(
              process.stderr,
              maxStderrBytes,
              'yt-dlp 错误输出超过限制',
              process,
            ),
          ]).timeout(
            timeout,
            onTimeout: () {
              process.kill();
              throw TimeoutException('yt-dlp 解析超过 ${timeout.inSeconds} 秒');
            },
          );
      if (_cancelRequested) {
        throw const YtDlpException('网页视频解析已取消');
      }
      return YtDlpProcessResult(
        exitCode: completed[0] as int,
        stdout: utf8.decode(completed[1] as List<int>, allowMalformed: true),
        stderr: utf8.decode(completed[2] as List<int>, allowMalformed: true),
      );
    } finally {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill();
      }
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
  }

  Future<List<int>> _readBounded(
    Stream<List<int>> stream,
    int limit,
    String message,
    Process process,
  ) async {
    final List<int> output = <int>[];
    await for (final List<int> chunk in stream) {
      if (output.length + chunk.length > limit) {
        process.kill();
        throw YtDlpException(message);
      }
      output.addAll(chunk);
    }
    return output;
  }

  @override
  void cancel() {
    _cancelRequested = true;
    _activeProcess?.kill();
  }
}

class YtDlpResolver implements WebVideoResolver {
  YtDlpResolver({
    YtDlpProcessRunner? processRunner,
    String Function()? executableLocator,
    DouyinBrowserResolver? douyinBrowserResolver,
    bool? isWindows,
    this.timeout = defaultYtDlpTimeout,
  }) : _processRunner = processRunner ?? BoundedYtDlpProcessRunner(),
       _executableLocator = executableLocator ?? _locateYtDlpExecutable,
       _isWindows = isWindows ?? Platform.isWindows {
    _douyinBrowserResolver =
        douyinBrowserResolver ??
        (_isWindows ? EdgeDouyinBrowserResolver(headless: false) : null);
  }

  final YtDlpProcessRunner _processRunner;
  final String Function() _executableLocator;
  final bool _isWindows;
  late final DouyinBrowserResolver? _douyinBrowserResolver;
  final Duration timeout;

  @override
  bool requiresExtraction(Uri uri) => !isDirectMediaUri(uri);

  @override
  Future<ResolvedWebVideo> resolve(
    Uri uri, {
    YtDlpBrowser? cookieBrowser,
  }) async {
    if (!requiresExtraction(uri)) return _directMedia(uri);
    if (!_isWindows) {
      throw const YtDlpException('Android 发送端暂只支持媒体直链；网页视频解析请使用 Windows 发送端');
    }

    final YtDlpProcessResult result;
    try {
      final List<String> arguments = <String>[
        '--ignore-config',
        '--no-playlist',
        '--skip-download',
        '--no-warnings',
        '--no-progress',
        '--no-color',
        '--socket-timeout',
        '10',
        '--retries',
        '1',
        '--extractor-retries',
        '1',
        '--fragment-retries',
        '1',
      ];
      if (cookieBrowser != null) {
        arguments.addAll(<String>[
          '--cookies-from-browser',
          cookieBrowser.name,
        ]);
      }
      arguments.addAll(<String>[
        '--format',
        'bv[vcodec^=avc1][protocol^=http]+ba[acodec^=mp4a][protocol^=http]/'
            'bv[vcodec^=avc1][protocol^=http]+ba[protocol^=http]/'
            'bv[protocol^=http]+ba[protocol^=http]/'
            'bv[vcodec^=avc1]+ba[acodec^=mp4a]/'
            'bv+ba/'
            'b[acodec!=none][vcodec!=none][protocol^=http]/'
            'b[acodec!=none][vcodec!=none]',
        '--dump-single-json',
        '--',
        uri.toString(),
      ]);
      result = await _processRunner.run(
        _executableLocator(),
        arguments,
        timeout: timeout,
        maxStdoutBytes: defaultYtDlpStdoutLimit,
        maxStderrBytes: defaultYtDlpStderrLimit,
      );
    } on TimeoutException {
      throw const YtDlpException('网页视频解析超时，请检查网络后重试');
    } on ProcessException {
      throw const YtDlpException(
        '未找到 yt-dlp.exe；请运行 scripts\\prepare-yt-dlp.ps1 后重试',
      );
    }
    if (result.exitCode != 0) {
      final DouyinBrowserResolver? douyinResolver = _douyinBrowserResolver;
      if (douyinResolver != null && isDouyinPageUri(uri)) {
        try {
          final DouyinBrowserResult browserResult = await douyinResolver
              .resolve(uri);
          final Uri? browserAudioUrl = browserResult.audioUrl;
          return ResolvedWebVideo(
            primaryTrack: ResolvedWebVideoTrack(
              url: browserResult.videoUrl,
              formatId: 'douyin-browser-video',
              contentLength: browserResult.videoContentLength,
              httpHeaders: browserResult.httpHeaders,
            ),
            audioTrack: browserAudioUrl == null
                ? null
                : ResolvedWebVideoTrack(
                    url: browserAudioUrl,
                    formatId: 'douyin-browser-audio',
                    contentLength: browserResult.audioContentLength,
                    httpHeaders: browserResult.httpHeaders,
                  ),
            name: _boundedName(browserResult.title),
            webpageUrl: uri,
            resolvedAt: DateTime.now().millisecondsSinceEpoch,
            cookieBrowser: cookieBrowser,
          );
        } on DouyinBrowserException catch (error) {
          final String diagnostic = _sanitizedYtDlpDiagnostic(result.stderr);
          throw YtDlpException(
            _withYtDlpDiagnostic('抖音页面解析失败：${error.message}', diagnostic),
          );
        }
      }
      throw _failureFor(result, cookieBrowser);
    }

    final Map<String, dynamic> metadata;
    try {
      final Object? decoded = jsonDecode(result.stdout.trim());
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      metadata = decoded;
    } on FormatException {
      throw const YtDlpException('yt-dlp 返回的数据格式无效，请更新 yt-dlp 后重试');
    }
    if (metadata['has_drm'] == true) {
      throw const YtDlpException('该视频受 DRM 保护，无法投放');
    }
    final (ResolvedWebVideoTrack, ResolvedWebVideoTrack?) tracks =
        _tracksFromMetadata(metadata);
    final Object? metadataTitle = metadata['title'];
    final String rawTitle = metadataTitle is String ? metadataTitle.trim() : '';
    return ResolvedWebVideo(
      primaryTrack: tracks.$1,
      audioTrack: tracks.$2,
      name: _boundedName(rawTitle.isEmpty ? _nameFromUri(uri) : rawTitle),
      webpageUrl: uri,
      resolvedAt: DateTime.now().millisecondsSinceEpoch,
      cookieBrowser: cookieBrowser,
    );
  }

  @override
  void cancel() {
    _processRunner.cancel();
    _douyinBrowserResolver?.cancel();
  }

  (ResolvedWebVideoTrack, ResolvedWebVideoTrack?) _tracksFromMetadata(
    Map<String, dynamic> metadata,
  ) {
    final Object? requestedFormats = metadata['requested_formats'];
    if (requestedFormats is List && requestedFormats.length > 1) {
      final List<Map<String, dynamic>> formats = requestedFormats
          .whereType<Map>()
          .map((Map<Object?, Object?> value) => value.cast<String, dynamic>())
          .toList();
      Map<String, dynamic>? video;
      Map<String, dynamic>? audio;
      for (final Map<String, dynamic> format in formats) {
        final bool hasVideo = _hasCodec(format['vcodec']);
        final bool hasAudio = _hasCodec(format['acodec']);
        if (video == null && hasVideo) video = format;
        if (audio == null && hasAudio && !hasVideo) audio = format;
      }
      if (video == null || audio == null) {
        throw const YtDlpException('yt-dlp 返回的分轨信息不完整');
      }
      final ResolvedWebVideoTrack videoTrack = _trackFromMetadata(
        video,
        fallback: metadata,
      );
      final ResolvedWebVideoTrack audioTrack = _trackFromMetadata(
        audio,
        fallback: metadata,
      );
      if (videoTrack.formatHint != null || audioTrack.formatHint != null) {
        throw const YtDlpException('该网页的分离音轨不是可直接播放的媒体文件');
      }
      return (videoTrack, audioTrack);
    }
    return (_trackFromMetadata(metadata), null);
  }

  ResolvedWebVideoTrack _trackFromMetadata(
    Map<String, dynamic> metadata, {
    Map<String, dynamic>? fallback,
  }) {
    if (metadata['has_drm'] == true) {
      throw const YtDlpException('该视频受 DRM 保护，无法投放');
    }
    final Object? rawMediaUrl = metadata['url'];
    final Uri? mediaUri = rawMediaUrl is String
        ? Uri.tryParse(rawMediaUrl)
        : null;
    if (mediaUri == null ||
        !<String>{'http', 'https'}.contains(mediaUri.scheme) ||
        mediaUri.host.isEmpty ||
        utf8.encode(mediaUri.toString()).length > 4096) {
      throw const YtDlpException('yt-dlp 未返回可用的 HTTP/HTTPS 媒体地址');
    }
    final Object? rawProtocol = metadata['protocol'] ?? fallback?['protocol'];
    final String protocol = rawProtocol is String
        ? rawProtocol.toLowerCase()
        : '';
    if (metadata['fragments'] is List && protocol.contains('dash_segments')) {
      throw const YtDlpException('该视频轨需要 yt-dlp 逐片下载，暂无法边解析边投放');
    }
    final Object? rawHeaders = metadata.containsKey('http_headers')
        ? metadata['http_headers']
        : fallback?['http_headers'];
    return ResolvedWebVideoTrack(
      url: mediaUri,
      formatId: _metadataString(metadata['format_id']),
      contentLength: _metadataContentLength(metadata, fallback),
      formatHint: protocol.contains('m3u8')
          ? 'hls'
          : protocol == 'dash'
          ? 'dash'
          : _formatHint(mediaUri),
      httpHeaders: _safeHeaders(rawHeaders),
    );
  }

  YtDlpException _failureFor(
    YtDlpProcessResult result,
    YtDlpBrowser? cookieBrowser,
  ) {
    final String detail = result.stderr.toLowerCase();
    final String diagnostic = _sanitizedYtDlpDiagnostic(result.stderr);
    if (detail.contains('unsupported url')) {
      return YtDlpException(
        _withYtDlpDiagnostic('当前 yt-dlp 不支持这个网页地址', diagnostic),
      );
    }
    if (detail.contains('drm')) {
      return YtDlpException(
        _withYtDlpDiagnostic('该视频受 DRM 保护，无法投放', diagnostic),
      );
    }
    if (detail.contains('sign in') ||
        detail.contains('login') ||
        detail.contains('cookies')) {
      if (cookieBrowser == null) {
        return YtDlpException(
          _withYtDlpDiagnostic('该网页需要登录，请在添加链接时选择使用浏览器登录状态', diagnostic),
        );
      }
      return YtDlpException(
        _withYtDlpDiagnostic(
          '无法使用 ${cookieBrowser.name} 的登录状态，请确认已在该浏览器登录',
          diagnostic,
        ),
      );
    }
    if (detail.contains('requested format is not available')) {
      return YtDlpException(
        _withYtDlpDiagnostic('该网页没有可直接播放的单路音视频格式', diagnostic),
      );
    }
    return YtDlpException(
      _withYtDlpDiagnostic('yt-dlp 解析失败（退出码 ${result.exitCode}）', diagnostic),
    );
  }
}

class YtDlpException implements Exception {
  const YtDlpException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _withYtDlpDiagnostic(String message, String diagnostic) =>
    diagnostic.isEmpty ? message : '$message\n详情：$diagnostic';

String _sanitizedYtDlpDiagnostic(String stderr) {
  final List<String> lines = stderr
      .split(RegExp(r'\r?\n'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';
  String diagnostic = lines.lastWhere(
    (String line) => line.toLowerCase().contains('error:'),
    orElse: () => lines.last,
  );
  diagnostic = diagnostic.replaceAll(
    RegExp(r'https?://[^\s\]\)]+', caseSensitive: false),
    '<URL>',
  );
  diagnostic = diagnostic
      .replaceAll(
        RegExp(r'"[A-Z]:\\[^"\r\n]+"', caseSensitive: false),
        '"<PATH>"',
      )
      .replaceAll(RegExp(r'\b[A-Z]:\\[^\s,;]+', caseSensitive: false), '<PATH>')
      .replaceAll(
        RegExp(r'"(?:/home|/Users)/[^"\r\n]+"', caseSensitive: false),
        '"<PATH>"',
      )
      .replaceAll(
        RegExp(r'(?:/home|/Users)/[^\s,;]+', caseSensitive: false),
        '<PATH>',
      );
  diagnostic = diagnostic.replaceAllMapped(
    RegExp(
      r'\b(authorization|proxy-authorization|cookie|set-cookie|token|password|api[-_]?key)\s*[:=].*$',
      caseSensitive: false,
    ),
    (Match match) => '${match.group(1)}=<redacted>',
  );
  diagnostic = diagnostic
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), ' ')
      .trim();
  final List<int> bytes = utf8.encode(diagnostic);
  if (bytes.length <= 600) return diagnostic;
  final StringBuffer bounded = StringBuffer();
  int byteCount = 0;
  for (final int rune in diagnostic.runes) {
    final String character = String.fromCharCode(rune);
    final int characterBytes = utf8.encode(character).length;
    if (byteCount + characterBytes > 597) break;
    bounded.write(character);
    byteCount += characterBytes;
  }
  return '$bounded...';
}

bool _hasCodec(Object? value) =>
    value is String && value.isNotEmpty && value.toLowerCase() != 'none';

String? _metadataString(Object? value) {
  if (value is! String) return null;
  final String normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _metadataContentLength(
  Map<String, dynamic> metadata,
  Map<String, dynamic>? fallback,
) {
  for (final Object? value in <Object?>[
    metadata['filesize'],
    metadata['filesize_approx'],
    fallback?['filesize'],
    fallback?['filesize_approx'],
  ]) {
    if (value is num && value.isFinite && value > 0) return value.round();
  }
  return null;
}

bool isDirectMediaUri(Uri uri) {
  if (uri.scheme == 'rtsp') return true;
  if (!<String>{'http', 'https'}.contains(uri.scheme)) return false;
  final String path = uri.path.toLowerCase();
  return const <String>{
    '.mp4',
    '.m4v',
    '.mkv',
    '.webm',
    '.mov',
    '.mp3',
    '.m4a',
    '.aac',
    '.wav',
    '.flac',
    '.ogg',
    '.m3u8',
    '.mpd',
  }.any(path.endsWith);
}

ResolvedWebVideo _directMedia(Uri uri) => ResolvedWebVideo(
  primaryTrack: ResolvedWebVideoTrack(
    url: uri,
    formatHint: _formatHint(uri),
    httpHeaders: const <String, String>{},
  ),
  name: _boundedName(_nameFromUri(uri)),
);

String _nameFromUri(Uri uri) {
  final String segment = uri.pathSegments.isEmpty
      ? uri.host
      : uri.pathSegments.last;
  return segment.isEmpty ? uri.host : Uri.decodeComponent(segment);
}

String? _formatHint(Uri uri) {
  final String path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8')) return 'hls';
  if (path.endsWith('.mpd')) return 'dash';
  if (uri.scheme == 'rtsp') return 'rtsp';
  return null;
}

Map<String, String> _safeHeaders(Object? rawHeaders) {
  if (rawHeaders is! Map) return <String, String>{};
  final Map<Object?, Object?> allowed = <Object?, Object?>{};
  for (final MapEntry<Object?, Object?> entry in rawHeaders.entries) {
    final Object? name = entry.key;
    if (name is String &&
        remoteHttpHeaderNames.containsKey(name.toLowerCase())) {
      allowed[name] = entry.value;
    }
  }
  return validateRemoteHttpHeaders(allowed);
}

String _boundedName(String value) {
  String result = value.trim();
  if (result.isEmpty) result = '网页视频';
  while (utf8.encode(result).length > 256) {
    result = String.fromCharCodes(result.runes.toList()..removeLast());
  }
  return result;
}

String _locateYtDlpExecutable() {
  final String? configured = Platform.environment['YT_DLP_PATH']?.trim();
  if (configured != null && configured.isNotEmpty) return configured;

  final List<String> candidates = <String>[
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}yt-dlp.exe',
    '${Directory.current.path}${Platform.pathSeparator}tools${Platform.pathSeparator}yt-dlp.exe',
    '${Directory.current.parent.path}${Platform.pathSeparator}tools${Platform.pathSeparator}yt-dlp.exe',
  ];
  for (final String candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return 'yt-dlp.exe';
}
