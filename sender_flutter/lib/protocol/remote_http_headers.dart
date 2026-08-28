import 'dart:convert';

const int maxRemoteHttpHeaders = 5;
const int maxRemoteHttpHeaderValueBytes = 2048;
const int maxRemoteHttpHeadersBytes = 4096;

const Map<String, String> remoteHttpHeaderNames = <String, String>{
  'user-agent': 'User-Agent',
  'referer': 'Referer',
  'origin': 'Origin',
  'accept': 'Accept',
  'accept-language': 'Accept-Language',
};

Map<String, String> validateRemoteHttpHeaders(Object? rawHeaders) {
  if (rawHeaders == null) return <String, String>{};
  if (rawHeaders is! Map) {
    throw const FormatException('httpHeaders must be an object');
  }
  if (rawHeaders.length > maxRemoteHttpHeaders) {
    throw const FormatException('too many remote HTTP headers');
  }

  final Map<String, String> normalized = <String, String>{};
  int totalBytes = 0;
  for (final MapEntry<Object?, Object?> entry in rawHeaders.entries) {
    final Object? rawName = entry.key;
    final Object? rawValue = entry.value;
    if (rawName is! String || rawValue is! String) {
      throw const FormatException(
        'HTTP header names and values must be strings',
      );
    }
    final String? name = remoteHttpHeaderNames[rawName.toLowerCase()];
    if (name == null) {
      throw FormatException('remote HTTP header is not allowed: $rawName');
    }
    if (normalized.containsKey(name)) {
      throw FormatException('duplicate remote HTTP header: $name');
    }
    if (rawValue.isEmpty ||
        rawValue.trim() != rawValue ||
        !rawValue.codeUnits.every(
          (int codeUnit) => codeUnit >= 0x20 && codeUnit <= 0x7e,
        )) {
      throw FormatException('invalid remote HTTP header value: $name');
    }
    final int valueBytes = utf8.encode(rawValue).length;
    if (valueBytes > maxRemoteHttpHeaderValueBytes) {
      throw FormatException('remote HTTP header value is too large: $name');
    }
    totalBytes += utf8.encode(name).length + valueBytes;
    if (totalBytes > maxRemoteHttpHeadersBytes) {
      throw const FormatException('remote HTTP headers are too large');
    }
    normalized[name] = rawValue;
  }
  return normalized;
}
