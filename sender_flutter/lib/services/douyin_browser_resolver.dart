import 'dart:async';
import 'dart:convert';
import 'dart:io';

const Duration _edgeStartupTimeout = Duration(seconds: 20);
const Duration _headlessPageLoadTimeout = Duration(seconds: 20);
const Duration _interactivePageLoadTimeout = Duration(seconds: 90);
const Duration _cdpCommandTimeout = Duration(seconds: 5);
const Duration _httpTimeout = Duration(seconds: 5);
const int _maxCdpResponseBytes = 1024 * 1024;
const int _maxMediaCandidates = 8;
const String _temporaryProfilePrefix = 'lan-media-cast-douyin-';
const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0';

abstract interface class DouyinBrowserResolver {
  Future<DouyinBrowserResult> resolve(Uri uri);

  void cancel();
}

class DouyinBrowserResult {
  const DouyinBrowserResult({
    required this.videoUrl,
    required this.title,
    required this.videoContentLength,
    this.audioUrl,
    this.audioContentLength,
  });

  final Uri videoUrl;
  final Uri? audioUrl;
  final String title;
  final int? videoContentLength;
  final int? audioContentLength;

  Map<String, String> get httpHeaders => const <String, String>{
    'User-Agent': _browserUserAgent,
    'Referer': 'https://www.douyin.com/',
  };
}

class DouyinBrowserException implements Exception {
  const DouyinBrowserException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EdgeDouyinBrowserResolver implements DouyinBrowserResolver {
  EdgeDouyinBrowserResolver({
    String Function()? executableLocator,
    this.headless = true,
    Duration? pageLoadTimeout,
  }) : _executableLocator = executableLocator ?? _locateEdgeExecutable,
       pageLoadTimeout =
           pageLoadTimeout ??
           (headless ? _headlessPageLoadTimeout : _interactivePageLoadTimeout);

  final String Function() _executableLocator;
  final bool headless;
  final Duration pageLoadTimeout;
  Process? _activeProcess;
  _CdpConnection? _activeConnection;
  bool _startPending = false;
  bool _cancelRequested = false;

  @override
  Future<DouyinBrowserResult> resolve(Uri uri) async {
    if (!isDouyinPageUri(uri)) {
      throw const DouyinBrowserException('不是可解析的抖音网页地址');
    }
    if (_startPending || _activeProcess != null || _activeConnection != null) {
      throw const DouyinBrowserException('已有抖音页面正在解析，请稍候');
    }

    _startPending = true;
    _cancelRequested = false;
    Directory? profile;
    _CdpConnection? connection;
    Process? process;
    try {
      await _cleanStaleTemporaryProfiles();
      _throwIfCancelled();
      profile = await Directory.systemTemp.createTemp(_temporaryProfilePrefix);
      final int debuggingPort = await _reserveLoopbackPort();
      process = await Process.start(_executableLocator(), <String>[
        if (headless) '--headless=new',
        '--disable-gpu',
        '--disable-extensions',
        '--disable-default-apps',
        '--disable-blink-features=AutomationControlled',
        '--no-first-run',
        '--mute-audio',
        '--autoplay-policy=no-user-gesture-required',
        '--remote-debugging-address=127.0.0.1',
        '--remote-debugging-port=$debuggingPort',
        '--remote-allow-origins=http://127.0.0.1:$debuggingPort',
        '--user-data-dir=${profile.path}',
        if (!headless) '--start-maximized',
        headless ? uri.toString() : '--app=${uri.toString()}',
      ], runInShell: false);
      _activeProcess = process;
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());

      final Uri debuggerUrl = await _waitForPageDebuggerUrl(debuggingPort);
      connection = await _CdpConnection.connect(debuggerUrl);
      _activeConnection = connection;
      await connection.call('Runtime.enable');

      final DouyinBrowserSnapshot snapshot = await _waitForMediaTracks(
        connection,
      );
      if (snapshot.combinedCandidates.isNotEmpty) {
        try {
          final _MediaProbe combined = await _selectTrack(
            snapshot.combinedCandidates,
            kind: '音视频',
          );
          return DouyinBrowserResult(
            videoUrl: combined.url,
            title: snapshot.title,
            videoContentLength: combined.contentLength,
          );
        } on DouyinBrowserException {
          if (snapshot.videoCandidates.isEmpty ||
              snapshot.audioCandidates.isEmpty) {
            rethrow;
          }
        }
      }
      if (snapshot.videoCandidates.isNotEmpty &&
          snapshot.audioCandidates.isNotEmpty) {
        final _MediaProbe video = await _selectTrack(
          snapshot.videoCandidates,
          kind: '视频',
        );
        final _MediaProbe audio = await _selectTrack(
          snapshot.audioCandidates,
          kind: '音频',
        );
        return DouyinBrowserResult(
          videoUrl: video.url,
          audioUrl: audio.url,
          title: snapshot.title,
          videoContentLength: video.contentLength,
          audioContentLength: audio.contentLength,
        );
      }
      throw const DouyinBrowserException('抖音页面未提供可播放的音视频地址');
    } on ProcessException {
      throw const DouyinBrowserException('未找到 Microsoft Edge，无法启用抖音页面解析');
    } on TimeoutException catch (error) {
      if (_cancelRequested) {
        throw const DouyinBrowserException('抖音页面解析已取消');
      }
      throw DouyinBrowserException(error.message ?? '抖音页面解析超时');
    } on DouyinBrowserException {
      rethrow;
    } catch (_) {
      if (_cancelRequested) {
        throw const DouyinBrowserException('抖音页面解析已取消');
      }
      throw const DouyinBrowserException('Microsoft Edge 页面解析异常');
    } finally {
      try {
        if (connection != null) {
          try {
            await connection.call('Browser.close');
          } catch (_) {
            // The browser may close the socket before acknowledging Browser.close.
          }
          try {
            await connection.close();
          } catch (_) {
            // Process termination and profile deletion are still mandatory.
          }
        }
        await _stopProcess(process);
        if (profile != null) await _deleteTemporaryProfile(profile);
      } finally {
        if (identical(_activeConnection, connection)) _activeConnection = null;
        if (identical(_activeProcess, process)) _activeProcess = null;
        _startPending = false;
      }
    }
  }

  Future<Uri> _waitForPageDebuggerUrl(int port) async {
    final DateTime deadline = DateTime.now().add(_edgeStartupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      _throwIfCancelled();
      try {
        final Map<String, dynamic> version = await _readJsonObject(
          Uri.parse('http://127.0.0.1:$port/json/version'),
        );
        final String browser = version['Browser'] as String? ?? '';
        if (!browser.startsWith('Edg/')) {
          throw const DouyinBrowserException('本地调试端口不是 Microsoft Edge');
        }
        final List<dynamic> targets = await _readJsonList(
          Uri.parse('http://127.0.0.1:$port/json/list'),
        );
        for (final Object? rawTarget in targets) {
          if (rawTarget is! Map) continue;
          final Map<String, dynamic> target = rawTarget.cast<String, dynamic>();
          final Uri? pageUri = Uri.tryParse(target['url'] as String? ?? '');
          final Uri? debuggerUri = Uri.tryParse(
            target['webSocketDebuggerUrl'] as String? ?? '',
          );
          if (target['type'] == 'page' &&
              pageUri != null &&
              isDouyinPageUri(pageUri) &&
              debuggerUri != null &&
              debuggerUri.scheme == 'ws' &&
              debuggerUri.host == '127.0.0.1' &&
              debuggerUri.port == port) {
            return debuggerUri;
          }
        }
      } on FormatException {
        // The local DevTools endpoint may not be ready yet.
      } on HttpException {
        // The local DevTools endpoint may not be ready yet.
      } on SocketException {
        // The local DevTools endpoint may not be ready yet.
      } on TimeoutException {
        // The local DevTools endpoint may not be ready yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('等待抖音页面打开超时');
  }

  Future<DouyinBrowserSnapshot> _waitForMediaTracks(
    _CdpConnection connection,
  ) async {
    final DateTime deadline = DateTime.now().add(pageLoadTimeout);
    DouyinBrowserSnapshot? latest;
    while (DateTime.now().isBefore(deadline)) {
      _throwIfCancelled();
      final Map<String, dynamic> result;
      try {
        result = await connection.call('Runtime.evaluate', <String, Object>{
          'expression': _snapshotExpression,
          'awaitPromise': true,
          'returnByValue': true,
        });
      } on TimeoutException {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      latest = DouyinBrowserSnapshot.fromEvaluation(result);
      if (!isDouyinPageUri(latest.pageUri)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      if (latest.combinedCandidates.isNotEmpty ||
          (latest.videoCandidates.isNotEmpty &&
              latest.audioCandidates.isNotEmpty)) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (latest?.challengeVisible ?? false) {
      throw const DouyinBrowserException('未在限定时间内完成抖音安全验证，请重试');
    }
    if (latest != null && !isDouyinPageUri(latest.pageUri)) {
      throw const DouyinBrowserException('抖音页面未完成受信任跳转');
    }
    throw TimeoutException('等待抖音视频地址超时');
  }

  Future<_MediaProbe> _selectTrack(
    List<Uri> candidates, {
    required String kind,
  }) async {
    final List<_MediaProbe> probes = <_MediaProbe>[];
    for (final Uri candidate in candidates.take(_maxMediaCandidates)) {
      _throwIfCancelled();
      final _MediaProbe? probe = await _probeMedia(candidate);
      if (probe != null) probes.add(probe);
    }
    if (probes.isEmpty) {
      throw DouyinBrowserException('抖音$kind地址不可访问');
    }
    probes.sort(
      (_MediaProbe left, _MediaProbe right) =>
          (right.contentLength ?? 0).compareTo(left.contentLength ?? 0),
    );
    return probes.first;
  }

  Future<_MediaProbe?> _probeMedia(Uri uri) async {
    final HttpClient client = HttpClient()..connectionTimeout = _httpTimeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(_httpTimeout);
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
        ..set(HttpHeaders.refererHeader, 'https://www.douyin.com/')
        ..set(HttpHeaders.userAgentHeader, _browserUserAgent);
      final HttpClientResponse response = await request.close().timeout(
        _httpTimeout,
      );
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        return null;
      }
      final String contentType =
          response.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (contentType != 'video/mp4' &&
          contentType != 'audio/mp4' &&
          contentType != 'application/octet-stream') {
        return null;
      }
      final int? totalLength = _contentLengthFromResponse(response);
      return _MediaProbe(uri, totalLength);
    } on HttpException {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void cancel() {
    _cancelRequested = true;
    unawaited(_activeConnection?.close());
    _activeProcess?.kill();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const DouyinBrowserException('抖音页面解析已取消');
    }
  }
}

bool isDouyinPageUri(Uri uri) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  final String host = uri.host.toLowerCase();
  return host == 'douyin.com' ||
      host.endsWith('.douyin.com') ||
      host == 'iesdouyin.com' ||
      host.endsWith('.iesdouyin.com');
}

String _locateEdgeExecutable() {
  final List<String> roots = <String>[
    if (Platform.environment['ProgramFiles(x86)'] case final String value)
      value,
    if (Platform.environment['ProgramFiles'] case final String value) value,
    if (Platform.environment['LOCALAPPDATA'] case final String value) value,
  ];
  for (final String root in roots) {
    final String candidate =
        '$root${Platform.pathSeparator}Microsoft${Platform.pathSeparator}'
        'Edge${Platform.pathSeparator}Application${Platform.pathSeparator}'
        'msedge.exe';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'msedge.exe';
}

Future<int> _reserveLoopbackPort() async {
  final ServerSocket socket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = socket.port;
  await socket.close();
  return port;
}

Future<List<dynamic>> _readJsonList(Uri uri) async {
  final Object? decoded = await _readJson(uri);
  if (decoded is! List) throw const FormatException('Invalid DevTools data');
  return decoded;
}

Future<Map<String, dynamic>> _readJsonObject(Uri uri) async {
  final Object? decoded = await _readJson(uri);
  if (decoded is! Map) throw const FormatException('Invalid DevTools data');
  return decoded.cast<String, dynamic>();
}

Future<Object?> _readJson(Uri uri) async {
  final HttpClient client = HttpClient()..connectionTimeout = _httpTimeout;
  try {
    final HttpClientRequest request = await client
        .getUrl(uri)
        .timeout(_httpTimeout);
    final HttpClientResponse response = await request.close().timeout(
      _httpTimeout,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'DevTools endpoint returned HTTP ${response.statusCode}',
      );
    }
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.timeout(_httpTimeout)) {
      if (bytes.length + chunk.length > _maxCdpResponseBytes) {
        throw const FormatException('DevTools response is too large');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  } finally {
    client.close(force: true);
  }
}

int? _contentLengthFromResponse(HttpClientResponse response) {
  final String? contentRange = response.headers.value(
    HttpHeaders.contentRangeHeader,
  );
  final int? rangeTotal = parseDouyinContentRangeTotal(contentRange);
  if (rangeTotal != null && rangeTotal > 0) return rangeTotal;
  return response.statusCode == HttpStatus.ok && response.contentLength > 0
      ? response.contentLength
      : null;
}

int? parseDouyinContentRangeTotal(String? contentRange) {
  final Match? totalMatch = contentRange == null
      ? null
      : RegExp(r'^bytes [0-9]+-[0-9]+/([0-9]+)$').firstMatch(contentRange);
  return totalMatch == null ? null : int.tryParse(totalMatch.group(1)!);
}

Future<void> _stopProcess(Process? process) async {
  if (process == null) return;
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Profile deletion below remains the final guard against open handles.
    }
  }
}

Future<void> _deleteTemporaryProfile(Directory profile) async {
  for (int attempt = 0; attempt < 40; attempt++) {
    try {
      if (await profile.exists()) await profile.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  throw const DouyinBrowserException('临时浏览数据清理失败，请关闭临时 Edge 窗口后重试');
}

Future<void> _cleanStaleTemporaryProfiles() async {
  final DateTime cutoff = DateTime.now().subtract(const Duration(minutes: 5));
  int inspected = 0;
  try {
    await for (final FileSystemEntity entity in Directory.systemTemp.list(
      followLinks: false,
    )) {
      if (inspected >= 32) break;
      if (entity is! Directory ||
          !_basename(entity.path).startsWith(_temporaryProfilePrefix)) {
        continue;
      }
      inspected += 1;
      try {
        final FileStat stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // An active instance may still own the profile; never delete by force.
      }
    }
  } on FileSystemException {
    // Cleanup of the current profile remains mandatory in resolve().
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

class DouyinBrowserSnapshot {
  const DouyinBrowserSnapshot({
    required this.pageUri,
    required this.title,
    required this.combinedCandidates,
    required this.videoCandidates,
    required this.audioCandidates,
    required this.challengeVisible,
  });

  factory DouyinBrowserSnapshot.fromEvaluation(
    Map<String, dynamic> evaluation,
  ) {
    final Object? remoteObject = evaluation['result'];
    if (remoteObject is! Map || remoteObject['value'] is! String) {
      throw const DouyinBrowserException('无法读取抖音页面数据');
    }
    final Object? decoded = jsonDecode(remoteObject['value'] as String);
    if (decoded is! Map) {
      throw const DouyinBrowserException('抖音页面返回的数据格式无效');
    }
    final Map<String, dynamic> value = decoded.cast<String, dynamic>();
    final Uri? pageUri = Uri.tryParse(value['href'] as String? ?? '');
    if (pageUri == null) {
      throw const DouyinBrowserException('无法确认抖音页面地址');
    }
    final List<Uri> apiResources = _trustedMediaUris(value['apiResources']);
    final List<Uri> performanceResources = _trustedMediaUris(
      value['performanceResources'],
    );
    return DouyinBrowserSnapshot(
      pageUri: pageUri,
      title: _cleanTitle(value['title'] as String? ?? ''),
      combinedCandidates: apiResources.where(isDouyinCombinedTrackUri).toList(),
      videoCandidates: performanceResources
          .where(isDouyinVideoTrackUri)
          .toList(),
      audioCandidates: performanceResources
          .where(isDouyinAudioTrackUri)
          .toList(),
      challengeVisible: value['challengeVisible'] == true,
    );
  }

  final Uri pageUri;
  final String title;
  final List<Uri> combinedCandidates;
  final List<Uri> videoCandidates;
  final List<Uri> audioCandidates;
  final bool challengeVisible;
}

class _MediaProbe {
  const _MediaProbe(this.url, this.contentLength);

  final Uri url;
  final int? contentLength;
}

class _CdpConnection {
  _CdpConnection._(this._socket) {
    _subscription = _socket.listen(
      (dynamic event) {
        if (event is! String ||
            utf8.encode(event).length > _maxCdpResponseBytes) {
          return;
        }
        try {
          final Object? decoded = jsonDecode(event);
          if (decoded is! Map) return;
          final Map<String, dynamic> message = decoded.cast<String, dynamic>();
          final Object? rawId = message['id'];
          if (rawId is! int) return;
          _pending.remove(rawId)?.complete(message);
        } on FormatException {
          // Ignore malformed DevTools events; command responses remain bounded.
        }
      },
      onError: (Object error) => _handleDisconnect(
        const DouyinBrowserException('Edge 调试连接异常，抖音解析已中止'),
      ),
      onDone: () =>
          _handleDisconnect(const DouyinBrowserException('Edge 窗口已关闭，抖音解析已中止')),
    );
  }

  static Future<_CdpConnection> connect(Uri debuggerUrl) async {
    final WebSocket socket = await WebSocket.connect(
      debuggerUrl.toString(),
    ).timeout(_cdpCommandTimeout);
    return _CdpConnection._(socket);
  }

  final WebSocket _socket;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<dynamic> _subscription;
  int _nextId = 0;
  bool _closed = false;

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object>? parameters,
  ]) async {
    if (_closed) {
      throw const DouyinBrowserException('Edge 窗口已关闭，抖音解析已中止');
    }
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _socket.add(
        jsonEncode(<String, Object>{
          'id': id,
          'method': method,
          'params': ?parameters,
        }),
      );
    } catch (_) {
      _pending.remove(id);
      throw const DouyinBrowserException('Edge 调试连接异常，抖音解析已中止');
    }
    final Map<String, dynamic> message;
    try {
      message = await completer.future.timeout(_cdpCommandTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw TimeoutException('浏览器解析命令超时');
    }
    if (message['error'] case final Map error) {
      throw DouyinBrowserException('浏览器解析命令失败：${error['message'] ?? method}');
    }
    final Object? result = message['result'];
    return result is Map ? result.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending(const DouyinBrowserException('Edge 窗口已关闭，抖音解析已中止'));
    await _subscription.cancel();
    await _socket.close();
  }

  void _failPending(DouyinBrowserException error) {
    final List<Completer<Map<String, dynamic>>> pending = _pending.values
        .toList();
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _handleDisconnect(DouyinBrowserException error) {
    _closed = true;
    _failPending(error);
  }
}

List<Uri> _trustedMediaUris(Object? rawResources) =>
    (rawResources as List? ?? const <Object>[])
        .whereType<String>()
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where(isTrustedDouyinMediaUri)
        .toSet()
        .toList();

bool isTrustedDouyinMediaUri(Uri uri) {
  final String host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      uri.toString().length <= 4096 &&
      (host == 'douyinvod.com' ||
          host.endsWith('.douyinvod.com') ||
          host == '365yg.com' ||
          host.endsWith('.365yg.com'));
}

bool isDouyinVideoTrackUri(Uri uri) =>
    uri.path.toLowerCase().contains('media-video-avc1');

bool isDouyinAudioTrackUri(Uri uri) =>
    uri.path.toLowerCase().contains('media-audio-');

bool isDouyinCombinedTrackUri(Uri uri) {
  final String path = uri.path.toLowerCase();
  return !path.contains('media-video-') &&
      !path.contains('media-audio-') &&
      (path.contains('/video/tos/') ||
          uri.queryParameters['mime_type'] == 'video_mp4');
}

String _cleanTitle(String value) {
  final String title = value.trim().replaceFirst(RegExp(r'\s*-\s*抖音$'), '');
  return title.isEmpty ? '抖音视频' : title;
}

const String _snapshotExpression = r'''
(async () => {
  const video = document.querySelector('video');
  if (video) video.play().catch(() => {});
  let apiResources = [];
  const id = location.pathname.match(/\/video\/(\d+)/)?.[1];
  let detail = window.__lanMediaCastDouyinDetail || null;
  const now = Date.now();
  const lastAttempt = window.__lanMediaCastDouyinLastAttempt || 0;
  if (id && !detail && now - lastAttempt >= 10000) {
    window.__lanMediaCastDouyinLastAttempt = now;
    const controller = new AbortController();
    const abortTimer = setTimeout(() => controller.abort(), 2500);
    try {
      const response = await fetch(
        `/aweme/v1/web/aweme/detail/?aweme_id=${id}`,
        { credentials: 'include', signal: controller.signal }
      );
      detail = response.ok ? (await response.json()).aweme_detail : null;
      if (detail) window.__lanMediaCastDouyinDetail = detail;
    } catch (_) {
    } finally {
      clearTimeout(abortTimer);
    }
  }
  const source = detail?.video;
  const collect = (address) => {
    for (const url of address?.url_list || []) {
      if (typeof url === 'string') apiResources.push(url);
    }
  };
  collect(source?.play_addr_h264);
  for (const bitRate of source?.bit_rate || []) {
    const codec = String(
      bitRate?.format || bitRate?.gear_name || bitRate?.codec_type || ''
    ).toLowerCase();
    if (bitRate?.is_h265 === false || /h264|avc/.test(codec)) {
      collect(bitRate?.play_addr);
    }
  }
  return JSON.stringify({
    href: location.href,
    title: document.title,
    apiResources,
    performanceResources: performance.getEntriesByType('resource')
      .map((entry) => entry.name)
      .filter((url) => /douyinvod/i.test(url)),
    challengeVisible: Boolean(document.querySelector(
      'iframe[src*="verifycenter"], [class*="captcha"], [id*="captcha"]'
    ))
  });
})()
''';
