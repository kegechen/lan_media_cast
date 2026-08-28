import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'install_certificate.dart';

class LocalMediaAsset {
  const LocalMediaAsset({
    required this.assetId,
    required this.contentId,
    required this.name,
    required this.mime,
    required this.size,
    required this.modifiedAtMillis,
    required this.filePath,
  });

  final String assetId;
  final String contentId;
  final String name;
  final String mime;
  final int size;
  final int modifiedAtMillis;
  final String filePath;

  String cacheKey(String senderId) => '$senderId:$contentId';

  Map<String, Object> protocolSource(String senderId) => {
    'kind': 'local',
    'assetId': assetId,
    'assetContentId': contentId,
    'cacheKey': cacheKey(senderId),
    'name': name,
    'mime': mime,
    'size': size,
    'path': '/v1/media/$assetId',
  };
}

class ByteRange {
  const ByteRange(this.start, this.endInclusive);

  final int start;
  final int endInclusive;
  int get length => endInclusive - start + 1;

  static ByteRange? parse(String? header, int contentLength) {
    if (header == null) return null;
    if (contentLength <= 0 || !header.startsWith('bytes=')) {
      throw const MediaRangeException('invalid_range');
    }
    final String value = header.substring(6).trim();
    if (value.isEmpty || value.contains(',')) {
      throw const MediaRangeException('invalid_range');
    }
    final int separator = value.indexOf('-');
    if (separator < 0) throw const MediaRangeException('invalid_range');
    final String startText = value.substring(0, separator).trim();
    final String endText = value.substring(separator + 1).trim();
    if (startText.isEmpty) {
      final int? suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) {
        throw const MediaRangeException('invalid_range');
      }
      final int length = min(suffix, contentLength);
      return ByteRange(contentLength - length, contentLength - 1);
    }
    final int? start = int.tryParse(startText);
    if (start == null || start < 0 || start >= contentLength) {
      throw const MediaRangeException('range_not_satisfiable');
    }
    if (endText.isEmpty) return ByteRange(start, contentLength - 1);
    final int? requestedEnd = int.tryParse(endText);
    if (requestedEnd == null || requestedEnd < start) {
      throw const MediaRangeException('invalid_range');
    }
    return ByteRange(start, min(requestedEnd, contentLength - 1));
  }
}

class MediaRangeException implements Exception {
  const MediaRangeException(this.code);

  final String code;
}

class LocalMediaServer {
  LocalMediaServer({
    required InstallCertificate certificate,
    Duration previousTokenGracePeriod = const Duration(seconds: 10),
  }) : _certificate = certificate,
       _previousTokenGracePeriod = previousTokenGracePeriod;

  final InstallCertificate _certificate;
  final Duration _previousTokenGracePeriod;
  final Map<String, LocalMediaAsset> _assets = <String, LocalMediaAsset>{};
  final Map<String, int> _activeByAsset = <String, int>{};
  HttpServer? _server;
  String? _bearerToken;
  String? _previousBearerToken;
  DateTime? _previousTokenExpiresAt;
  int _activeRequests = 0;
  int _generation = 0;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;
  int get generation => _generation;
  String get certificateSha256 => _certificate.sha256Base64Url;
  String get bearerToken =>
      _bearerToken ?? (throw StateError('Media server is not running'));
  Iterable<LocalMediaAsset> get assets => _assets.values;

  Future<void> start() async {
    if (_server != null) return;
    final SecurityContext context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certificate.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(_certificate.privateKeyPem));
    _bearerToken = _randomToken();
    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      0,
      context,
      shared: true,
      backlog: 16,
    ).timeout(const Duration(seconds: 5));
    _server!.autoCompress = false;
    _generation += 1;
    unawaited(
      AppLog.instance.info(
        'media_server.started',
        fields: <String, Object?>{
          'bindAddress': '0.0.0.0',
          'port': _server!.port,
          'generation': _generation,
        },
      ),
    );
    unawaited(_serve(_server!));
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    final int? stoppedPort = server?.port;
    _server = null;
    _bearerToken = null;
    _previousBearerToken = null;
    _previousTokenExpiresAt = null;
    await server?.close(force: true);
    if (server != null) {
      unawaited(
        AppLog.instance.info(
          'media_server.stopped',
          fields: <String, Object?>{'port': stoppedPort},
        ),
      );
    }
  }

  void renewSession() {
    if (_server == null) throw StateError('Media server is not running');
    _previousBearerToken = _bearerToken;
    _previousTokenExpiresAt = DateTime.now().add(_previousTokenGracePeriod);
    _bearerToken = _randomToken();
    _generation += 1;
    unawaited(
      AppLog.instance.info(
        'media_server.session_renewed',
        fields: <String, Object?>{
          'port': _server!.port,
          'generation': _generation,
        },
      ),
    );
  }

  Future<LocalMediaAsset> registerFile(String filePath) async {
    final File file = File(filePath);
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw ArgumentError('所选文件不可读取或为空');
    }
    final RandomAccessFile handle = await file.open();
    try {
      const int sampleSize = 64 * 1024;
      final List<int> first = await handle.read(min(sampleSize, stat.size));
      final int tailStart = max(0, stat.size - sampleSize);
      await handle.setPosition(tailStart);
      final List<int> last = await handle.read(stat.size - tailStart);
      final Digest digest = sha256.convert(<int>[
        ...utf8.encode(file.absolute.path),
        ...utf8.encode(
          ':${stat.size}:${stat.modified.millisecondsSinceEpoch}:',
        ),
        ...first,
        ...last,
      ]);
      final LocalMediaAsset asset = LocalMediaAsset(
        assetId: const Uuid().v4(),
        contentId: base64Url.encode(digest.bytes).replaceAll('=', ''),
        name: path.basename(filePath),
        mime: _mimeFor(filePath),
        size: stat.size,
        modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
        filePath: file.absolute.path,
      );
      _assets[asset.assetId] = asset;
      unawaited(
        AppLog.instance.info(
          'media_file.registered',
          fields: <String, Object?>{
            'assetId': asset.assetId,
            'path': asset.filePath,
            'size': asset.size,
            'mime': asset.mime,
          },
        ),
      );
      return asset;
    } finally {
      await handle.close();
    }
  }

  void retainAssets(Set<String> assetIds) {
    final int previousCount = _assets.length;
    _assets.removeWhere(
      (String id, LocalMediaAsset _) => !assetIds.contains(id),
    );
    final int removedCount = previousCount - _assets.length;
    if (removedCount > 0) {
      unawaited(
        AppLog.instance.info(
          'media_file.unregistered',
          fields: <String, Object?>{
            'removedCount': removedCount,
            'remainingCount': _assets.length,
          },
        ),
      );
    }
  }

  Future<void> _serve(HttpServer server) async {
    final int serverPort = server.port;
    try {
      await for (final HttpRequest request in server) {
        unawaited(_handle(request));
      }
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'media_server.serve_failed',
          error,
          stackTrace: stackTrace,
          fields: <String, Object?>{'port': serverPort},
        ),
      );
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    final Stopwatch stopwatch = Stopwatch()..start();
    final String remoteAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final int? remotePort = request.connectionInfo?.remotePort;
    final String? rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    String? assetId;
    LocalMediaAsset? asset;
    int statusCode = HttpStatus.internalServerError;
    int bytesSent = 0;
    bool requestCounted = false;
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final List<String> segments = request.uri.pathSegments;
      assetId =
          segments.length == 3 && segments[0] == 'v1' && segments[1] == 'media'
          ? segments[2]
          : null;
      asset = assetId == null ? null : _assets[assetId];
      if (asset == null || assetId!.contains('..')) {
        statusCode = HttpStatus.notFound;
        await _finish(response, statusCode);
        return;
      }
      if (!_isAuthorized(
        request.headers.value(HttpHeaders.authorizationHeader),
      )) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        statusCode = HttpStatus.unauthorized;
        await _finish(response, statusCode);
        return;
      }
      if (request.method != 'HEAD' && request.method != 'GET') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        statusCode = HttpStatus.methodNotAllowed;
        await _finish(response, statusCode);
        return;
      }
      final FileStat currentStat;
      try {
        currentStat = await File(asset.filePath).stat();
      } on FileSystemException {
        statusCode = HttpStatus.notFound;
        await _finish(response, statusCode);
        return;
      }
      if (currentStat.type != FileSystemEntityType.file) {
        statusCode = HttpStatus.notFound;
        await _finish(response, statusCode);
        return;
      }
      if (currentStat.size != asset.size ||
          currentStat.modified.millisecondsSinceEpoch !=
              asset.modifiedAtMillis) {
        statusCode = HttpStatus.preconditionFailed;
        await _finish(response, statusCode);
        return;
      }
      final String etag = '"${asset.contentId}"';
      if (request.method == 'GET') {
        final String? ifMatch = request.headers.value(
          HttpHeaders.ifMatchHeader,
        );
        if (ifMatch == null) {
          statusCode = 428;
          await _finish(response, statusCode);
          return;
        }
        if (ifMatch != etag) {
          statusCode = HttpStatus.preconditionFailed;
          await _finish(response, statusCode);
          return;
        }
      }
      if (_activeRequests >= 4 || (_activeByAsset[assetId] ?? 0) >= 2) {
        response.headers.set(HttpHeaders.retryAfterHeader, '1');
        statusCode = HttpStatus.serviceUnavailable;
        await _finish(response, statusCode);
        return;
      }

      _activeRequests += 1;
      _activeByAsset[assetId] = (_activeByAsset[assetId] ?? 0) + 1;
      requestCounted = true;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, asset.mime)
        ..set(HttpHeaders.etagHeader, etag);
      if (request.method == 'HEAD') {
        response.contentLength = asset.size;
        statusCode = HttpStatus.ok;
        response.statusCode = statusCode;
        await response.close();
        return;
      }
      ByteRange? range;
      try {
        range = ByteRange.parse(
          request.headers.value(HttpHeaders.rangeHeader),
          asset.size,
        );
      } on MediaRangeException {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${asset.size}',
        );
        statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await _finish(response, statusCode);
        return;
      }
      final int start = range?.start ?? 0;
      final int endInclusive = range?.endInclusive ?? asset.size - 1;
      statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent;
      response.statusCode = statusCode;
      response.contentLength = endInclusive - start + 1;
      if (range != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$endInclusive/${asset.size}',
        );
      }
      await File(asset.filePath)
          .openRead(start, endInclusive + 1)
          .map((List<int> bytes) {
            bytesSent += bytes.length;
            return bytes;
          })
          .pipe(response);
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'media_request.failed',
          error,
          stackTrace: stackTrace,
          fields: <String, Object?>{
            'remoteAddress': remoteAddress,
            'remotePort': ?remotePort,
            'method': request.method,
            'assetId': ?assetId,
          },
        ),
      );
      try {
        response.statusCode = HttpStatus.internalServerError;
        statusCode = HttpStatus.internalServerError;
      } on StateError {
        // Headers may already be committed by a partially streamed response.
      }
      try {
        await response.close();
      } on Object {
        // The peer may have disconnected while a range was being streamed.
      }
    } finally {
      if (requestCounted) {
        _activeRequests -= 1;
        final int next = (_activeByAsset[assetId] ?? 1) - 1;
        if (next <= 0) {
          _activeByAsset.remove(assetId);
        } else {
          _activeByAsset[assetId!] = next;
        }
      }
      stopwatch.stop();
      unawaited(
        AppLog.instance.info(
          'media_request.completed',
          fields: <String, Object?>{
            'remoteAddress': remoteAddress,
            'remotePort': ?remotePort,
            'method': request.method,
            'statusCode': statusCode,
            if (rangeHeader != null)
              'range': rangeHeader.length <= 256
                  ? rangeHeader
                  : '${rangeHeader.substring(0, 256)}...',
            'bytesSent': bytesSent,
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'assetId': ?assetId,
            'name': ?asset?.name,
          },
        ),
      );
    }
  }

  bool _isAuthorized(String? authorization) {
    if (authorization == 'Bearer $_bearerToken') return true;
    final DateTime? expiresAt = _previousTokenExpiresAt;
    if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return authorization == 'Bearer $_previousBearerToken';
    }
    _previousBearerToken = null;
    _previousTokenExpiresAt = null;
    return false;
  }

  Future<void> _finish(HttpResponse response, int statusCode) async {
    response.statusCode = statusCode;
    response.contentLength = 0;
    await response.close();
  }

  String _randomToken() {
    final Random random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  String _mimeFor(String filePath) {
    switch (path.extension(filePath).toLowerCase()) {
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      default:
        return 'application/octet-stream';
    }
  }
}
