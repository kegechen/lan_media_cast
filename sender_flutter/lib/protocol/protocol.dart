import 'dart:convert';

const int protocolVersion = 1;
const int maxUdpBytes = 1400;
const int maxTextFrameBytes = 64 * 1024;
const int maxBinaryFrameBytes = 128 * 1024;
const int maxNameBytes = 256;
const int maxPlaylistItems = 500;
const int maxPhotoItems = 9;

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
final RegExp _typePattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

bool isValidMessageType(String type) => _typePattern.hasMatch(type);
bool isValidUuid(String value) => _uuidPattern.hasMatch(value);

String _describeMessageType(String type) {
  final String shortened = type.length <= 64
      ? type
      : '${type.substring(0, 64)}...';
  return jsonEncode(shortened);
}

const Set<String> _sideEffectTypes = {
  'media.endpoint.announce',
  'playlist.replace',
  'mode.set',
  'player.play',
  'player.pause',
  'player.stop',
  'player.seek',
  'player.select',
  'player.next',
  'player.previous',
  'player.repeat',
  'player.volume',
  'player.mute',
  'photo.batch.start',
  'photo.batch.update',
  'photo.batch.cancel',
  'photo.item.meta',
  'photo.batch.resume.query',
  'photo.operation',
};

class ProtocolException implements Exception {
  ProtocolException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ProtocolException($code): $message';
}

class DiscoveryQuery {
  const DiscoveryQuery({
    required this.requestId,
    required this.senderId,
    required this.senderName,
  });

  final String requestId;
  final String senderId;
  final String senderName;

  Map<String, Object> toJson() => {
    'v': protocolVersion,
    'type': 'discover.query',
    'requestId': requestId,
    'senderId': senderId,
    'senderName': senderName,
  };

  static DiscoveryQuery decode(List<int> bytes) {
    if (bytes.length > maxUdpBytes) {
      throw ProtocolException(
        'message_too_large',
        'UDP datagram exceeds protocol limit',
      );
    }
    final Map<String, dynamic> value = _decodeObject(utf8.decode(bytes));
    _expectVersionAndType(value, 'discover.query');
    final String requestId = _requiredString(value, 'requestId');
    final String senderId = _requiredString(value, 'senderId');
    final String senderName = _requiredString(value, 'senderName');
    _requireUuid(requestId, 'requestId');
    _requireUuid(senderId, 'senderId');
    final int nameLength = utf8.encode(senderName).length;
    if (nameLength < 1 || nameLength > maxNameBytes) {
      throw ProtocolException(
        'invalid_message',
        'senderName has an invalid UTF-8 length',
      );
    }
    return DiscoveryQuery(
      requestId: requestId,
      senderId: senderId,
      senderName: senderName,
    );
  }
}

class DiscoveryResponse {
  const DiscoveryResponse({
    required this.requestId,
    required this.deviceId,
    required this.deviceName,
    required this.wssPort,
    required this.busy,
    required this.pairingRequired,
    required this.protocolMin,
    required this.protocolMax,
    required this.capabilities,
  });

  final String requestId;
  final String deviceId;
  final String deviceName;
  final int wssPort;
  final bool busy;
  final bool pairingRequired;
  final int protocolMin;
  final int protocolMax;
  final List<String> capabilities;

  static DiscoveryResponse decode(List<int> bytes) {
    if (bytes.length > maxUdpBytes) {
      throw ProtocolException(
        'message_too_large',
        'UDP datagram exceeds protocol limit',
      );
    }
    final Map<String, dynamic> value = _decodeObject(utf8.decode(bytes));
    _expectVersionAndType(value, 'discover.response');
    final String requestId = _requiredString(value, 'requestId');
    final String deviceId = _requiredString(value, 'deviceId');
    _requireUuid(requestId, 'requestId');
    _requireUuid(deviceId, 'deviceId');
    final String deviceName = _requiredString(value, 'deviceName');
    final int nameLength = utf8.encode(deviceName).length;
    if (nameLength < 1 || nameLength > maxNameBytes) {
      throw ProtocolException(
        'invalid_message',
        'deviceName has an invalid UTF-8 length',
      );
    }
    final int wssPort = _requiredInt(value, 'wssPort');
    if (wssPort < 1 || wssPort > 65535) {
      throw ProtocolException(
        'invalid_message',
        'wssPort is outside the valid range',
      );
    }
    final Object? rawCapabilities = value['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.any((item) => item is! String)) {
      throw ProtocolException(
        'invalid_message',
        'capabilities must be a string list',
      );
    }
    return DiscoveryResponse(
      requestId: requestId,
      deviceId: deviceId,
      deviceName: deviceName,
      wssPort: wssPort,
      busy: _requiredBool(value, 'busy'),
      pairingRequired: _requiredBool(value, 'pairingRequired'),
      protocolMin: _requiredInt(value, 'protocolMin'),
      protocolMax: _requiredInt(value, 'protocolMax'),
      capabilities: rawCapabilities.cast<String>(),
    );
  }
}

class ProtocolEnvelope {
  const ProtocolEnvelope({
    required this.version,
    required this.type,
    required this.timestamp,
    required this.payload,
    this.id,
    this.replyTo,
    this.sessionId,
    this.commandSeq,
  });

  final int version;
  final String type;
  final String? id;
  final String? replyTo;
  final String? sessionId;
  final int? commandSeq;
  final int timestamp;
  final Map<String, dynamic> payload;

  factory ProtocolEnvelope.decode(String text) {
    if (utf8.encode(text).length > maxTextFrameBytes) {
      throw ProtocolException(
        'message_too_large',
        'WSS text frame exceeds protocol limit',
      );
    }
    final Map<String, dynamic> value = _decodeObject(text);
    final int version = _requiredInt(value, 'v');
    final String type = _requiredString(value, 'type');
    _expectVersionAndType(value, type);
    if (!isValidMessageType(type)) {
      throw ProtocolException(
        'invalid_message',
        'Invalid message type: ${_describeMessageType(type)}',
      );
    }
    final String? id = _optionalString(value, 'id');
    final String? replyTo = _optionalString(value, 'replyTo');
    final String? sessionId = _optionalString(value, 'sessionId');
    final int? commandSeq = _optionalInt(value, 'commandSeq');
    final int timestamp = _requiredInt(value, 'ts');
    final Object? rawPayload = value['payload'];
    if (rawPayload is! Map<String, dynamic>) {
      throw ProtocolException('invalid_message', 'payload must be an object');
    }
    for (final ({String field, String? value}) candidate in [
      (field: 'id', value: id),
      (field: 'replyTo', value: replyTo),
      (field: 'sessionId', value: sessionId),
    ]) {
      if (candidate.value != null) {
        _requireUuid(candidate.value!, candidate.field);
      }
    }
    if (commandSeq != null && commandSeq < 1) {
      throw ProtocolException('invalid_message', 'commandSeq must be positive');
    }
    if (_sideEffectTypes.contains(type) &&
        (id == null || sessionId == null || commandSeq == null)) {
      throw ProtocolException(
        'invalid_message',
        'Command requires id, sessionId and commandSeq',
      );
    }
    if (type == 'session.hello' && (sessionId != null || commandSeq != null)) {
      throw ProtocolException(
        'invalid_message',
        'session.hello must be outside a session',
      );
    }
    if (type == 'protocol.error') {
      if (replyTo != null || commandSeq != null || rawPayload['ok'] != false) {
        throw ProtocolException(
          'invalid_message',
          'Invalid protocol.error envelope',
        );
      }
      const Set<String> reasons = {
        'malformed_binary_header',
        'unknown_transfer',
        'internal_error',
      };
      if (!reasons.contains(rawPayload['reason']) ||
          !rawPayload.containsKey('transferId')) {
        throw ProtocolException(
          'invalid_message',
          'Invalid protocol.error reason',
        );
      }
    }
    return ProtocolEnvelope(
      version: version,
      type: type,
      id: id,
      replyTo: replyTo,
      sessionId: sessionId,
      commandSeq: commandSeq,
      timestamp: timestamp,
      payload: rawPayload,
    );
  }

  Map<String, dynamic> toJson() {
    if (!isValidMessageType(type)) {
      throw ProtocolException(
        'invalid_message',
        'Invalid message type: ${_describeMessageType(type)}',
      );
    }
    return <String, dynamic>{
      'v': version,
      'type': type,
      if (id != null) 'id': id,
      if (replyTo != null) 'replyTo': replyTo,
      if (sessionId != null) 'sessionId': sessionId,
      if (commandSeq != null) 'commandSeq': commandSeq,
      'ts': timestamp,
      'payload': payload,
    };
  }
}

Map<String, dynamic> _decodeObject(String text) {
  try {
    final Object? value = jsonDecode(text);
    if (value is Map<String, dynamic>) return value;
  } on FormatException catch (error) {
    throw ProtocolException(
      'invalid_message',
      'Malformed JSON: ${error.message}',
    );
  }
  throw ProtocolException('invalid_message', 'JSON root must be an object');
}

void _expectVersionAndType(Map<String, dynamic> value, String expectedType) {
  if (_requiredInt(value, 'v') != protocolVersion) {
    throw ProtocolException(
      'unsupported_version',
      'Unsupported protocol version',
    );
  }
  if (_requiredString(value, 'type') != expectedType) {
    throw ProtocolException('invalid_message', 'Unexpected message type');
  }
}

void _requireUuid(String value, String field) {
  if (!_uuidPattern.hasMatch(value)) {
    throw ProtocolException(
      'invalid_message',
      '$field must be an RFC 4122 UUID',
    );
  }
}

String _requiredString(Map<String, dynamic> value, String name) {
  final Object? field = value[name];
  if (field is String) return field;
  throw ProtocolException('invalid_message', 'Missing or invalid $name');
}

String? _optionalString(Map<String, dynamic> value, String name) {
  final Object? field = value[name];
  if (field == null || field is String) return field as String?;
  throw ProtocolException('invalid_message', 'Invalid $name');
}

int _requiredInt(Map<String, dynamic> value, String name) {
  final Object? field = value[name];
  if (field is int) return field;
  throw ProtocolException('invalid_message', 'Missing or invalid $name');
}

int? _optionalInt(Map<String, dynamic> value, String name) {
  final Object? field = value[name];
  if (field == null || field is int) return field as int?;
  throw ProtocolException('invalid_message', 'Invalid $name');
}

bool _requiredBool(Map<String, dynamic> value, String name) {
  final Object? field = value[name];
  if (field is bool) return field;
  throw ProtocolException('invalid_message', 'Missing or invalid $name');
}
