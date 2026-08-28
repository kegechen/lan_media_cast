import 'dart:convert';

import 'remote_http_headers.dart';

Map<String, Object> validateRemoteMediaSource(Object? rawSource) {
  if (rawSource is! Map) {
    throw const FormatException('remote media source must be an object');
  }
  if (rawSource['kind'] != 'url') {
    throw const FormatException('remote media source kind must be url');
  }
  final Object? rawName = rawSource['name'];
  if (rawName is! String ||
      rawName.trim().isEmpty ||
      utf8.encode(rawName).length > 256) {
    throw const FormatException('remote media source name is invalid');
  }
  final Map<String, Object> normalized = <String, Object>{
    'kind': 'url',
    'name': rawName,
    ...validateRemoteMediaTrack(rawSource, allowRtsp: true),
  };
  final Object? rawAudioTrack = rawSource['audioTrack'];
  if (rawAudioTrack != null) {
    normalized['audioTrack'] = validateRemoteMediaTrack(
      rawAudioTrack,
      allowRtsp: false,
      allowAdaptiveManifest: false,
    );
    if (normalized['formatHint'] != null) {
      throw const FormatException(
        'split remote media tracks must be progressive files',
      );
    }
  }
  return normalized;
}

Map<String, Object> validateRemoteMediaTrack(
  Object? rawTrack, {
  required bool allowRtsp,
  bool allowAdaptiveManifest = true,
}) {
  if (rawTrack is! Map) {
    throw const FormatException('remote media track must be an object');
  }
  final Object? rawUrl = rawTrack['url'];
  if (rawUrl is! String || utf8.encode(rawUrl).length > 4096) {
    throw const FormatException('remote media URL is invalid');
  }
  final Uri? uri = Uri.tryParse(rawUrl);
  final Set<String> allowedSchemes = allowRtsp
      ? const <String>{'http', 'https', 'rtsp'}
      : const <String>{'http', 'https'};
  if (uri == null || !allowedSchemes.contains(uri.scheme) || uri.host.isEmpty) {
    throw const FormatException('remote media URL is invalid');
  }
  final Object? rawFormatHint = rawTrack['formatHint'];
  if (rawFormatHint != null &&
      (rawFormatHint is! String ||
          !const <String>{'hls', 'dash', 'rtsp'}.contains(rawFormatHint))) {
    throw const FormatException('remote media format is invalid');
  }
  if (!allowAdaptiveManifest && rawFormatHint != null) {
    throw const FormatException(
      'split remote media tracks must be progressive files',
    );
  }
  if ((rawFormatHint == 'rtsp') != (uri.scheme == 'rtsp')) {
    throw const FormatException('RTSP format and URL must match');
  }
  final Object? rawCacheKey = rawTrack['cacheKey'];
  if (rawCacheKey != null &&
      (rawCacheKey is! String ||
          rawCacheKey.isEmpty ||
          utf8.encode(rawCacheKey).length > 256)) {
    throw const FormatException('remote media cache key is invalid');
  }
  final Map<String, String> headers = validateRemoteHttpHeaders(
    rawTrack['httpHeaders'],
  );
  if (uri.scheme == 'rtsp' && headers.isNotEmpty) {
    throw const FormatException('RTSP source cannot contain HTTP headers');
  }
  return <String, Object>{
    'url': uri.toString(),
    'formatHint': ?rawFormatHint,
    'cacheKey': ?rawCacheKey,
    if (headers.isNotEmpty) 'httpHeaders': headers,
  };
}
