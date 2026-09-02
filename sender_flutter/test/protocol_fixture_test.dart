import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/protocol/protocol.dart';
import 'package:lan_media_cast_sender/protocol/remote_http_headers.dart';
import 'package:lan_media_cast_sender/protocol/remote_media_source.dart';

void main() {
  final Directory fixtures = Directory('../protocol/fixtures/v1');

  String fixture(String relativePath) {
    final File file = File('${fixtures.path}/$relativePath');
    expect(file.existsSync(), isTrue, reason: 'Missing fixture: ${file.path}');
    return file.readAsStringSync();
  }

  test('valid discovery fixtures decode', () {
    final DiscoveryQuery query = DiscoveryQuery.decode(
      File('${fixtures.path}/valid/discover_query.json').readAsBytesSync(),
    );
    expect(query.senderName, 'Teacher-PC');

    final DiscoveryResponse response = DiscoveryResponse.decode(
      File('${fixtures.path}/valid/discover_response.json').readAsBytesSync(),
    );
    expect(response.wssPort, 39881);
  });

  test('valid envelope fixtures decode', () {
    expect(
      ProtocolEnvelope.decode(fixture('valid/command_envelope.json')).type,
      'player.play',
    );
    expect(
      ProtocolEnvelope.decode(fixture('valid/protocol_error.json')).type,
      'protocol.error',
    );
    expect(
      ProtocolEnvelope.decode(
        fixture('valid/protocol_internal_error.json'),
      ).payload['reason'],
      'internal_error',
    );
    expect(
      ProtocolEnvelope.decode(fixture('valid/response_envelope.json')).type,
      'response',
    );
    final ProtocolEnvelope ready = ProtocolEnvelope.decode(
      fixture('valid/session_ready.json'),
    );
    expect(ready.payload['deviceName'], 'Projector-01');
    expect(ready.payload['playlistRevision'], 12);
    expect(
      ProtocolEnvelope.decode(
        fixture('valid/pairing_expired_response.json'),
      ).payload['error'],
      containsPair('code', 'pairing_expired'),
    );
    expect(
      ProtocolEnvelope.decode(fixture('valid/photo_batch_ready.json')).type,
      'photo.batch.ready',
    );
    expect(
      ProtocolEnvelope.decode(fixture('valid/photo_item_ready.json')).type,
      'photo.item.ready',
    );
    expect(
      ProtocolEnvelope.decode(fixture('valid/receiver_logs_get.json')).type,
      'diagnostics.logs.get',
    );
    final ProtocolEnvelope resume = ProtocolEnvelope.decode(
      fixture('valid/photo_batch_resume_state.json'),
    );
    _validatePhotoResumePayload(resume.payload);
    expect(
      ProtocolEnvelope.decode(
        fixture('valid/photo_protocol_unknown_transfer.json'),
      ).payload['reason'],
      'unknown_transfer',
    );
    expect(
      ProtocolEnvelope.decode(
        fixture('valid/photo_protocol_malformed_header.json'),
      ).payload['transferId'],
      isNull,
    );
  });

  test('invalid fixtures are rejected', () {
    expect(
      () => DiscoveryQuery.decode(
        File(
          '${fixtures.path}/invalid/discover_wrong_version.json',
        ).readAsBytesSync(),
      ),
      throwsA(isA<ProtocolException>()),
    );
    for (final String name in [
      'command_missing_sequence.json',
      'invalid_message_type.json',
      'protocol_error_with_reply.json',
    ]) {
      expect(
        () => ProtocolEnvelope.decode(fixture('invalid/$name')),
        throwsA(isA<ProtocolException>()),
      );
    }
    final ProtocolEnvelope invalidResume = ProtocolEnvelope.decode(
      fixture('invalid/photo_resume_missing_nullable.json'),
    );
    expect(
      () => _validatePhotoResumePayload(invalidResume.payload),
      throwsFormatException,
    );
  });

  test('remote HTTP header fixtures enforce the shared allowlist', () {
    final Map<String, dynamic> valid =
        jsonDecode(fixture('valid/remote_http_headers.json'))
            as Map<String, dynamic>;
    expect(validateRemoteHttpHeaders(valid).keys, <String>[
      'User-Agent',
      'Referer',
      'Origin',
      'Accept',
      'Accept-Language',
    ]);

    final Map<String, dynamic> invalid =
        jsonDecode(fixture('invalid/remote_http_headers.json'))
            as Map<String, dynamic>;
    for (final Object? rawCase in invalid['cases']! as List<dynamic>) {
      expect(() => validateRemoteHttpHeaders(rawCase), throwsFormatException);
    }
  });

  test('split remote media source fixtures are synchronized', () {
    final Map<String, dynamic> valid =
        jsonDecode(fixture('valid/split_remote_media_source.json'))
            as Map<String, dynamic>;
    final Map<String, Object> normalized = validateRemoteMediaSource(valid);
    expect(normalized['cacheKey'], 'web:example:primary');
    expect(
      normalized['audioTrack'],
      isA<Map<String, Object>>().having(
        (Map<String, Object> track) => track['cacheKey'],
        'cacheKey',
        'web:example:audio',
      ),
    );

    final Map<String, dynamic> invalid =
        jsonDecode(fixture('invalid/split_remote_media_source.json'))
            as Map<String, dynamic>;
    for (final Object? rawCase in invalid['cases']! as List<dynamic>) {
      expect(() => validateRemoteMediaSource(rawCase), throwsFormatException);
    }
  });
}

void _validatePhotoResumePayload(Map<String, dynamic> payload) {
  final Object? rawItems = payload['items'];
  if (rawItems is! List<dynamic>) throw const FormatException('items missing');
  const Set<String> statuses = <String>{
    'awaitingMeta',
    'ready',
    'partial',
    'complete',
    'removed',
  };
  final Set<String> seen = <String>{};
  for (final Object? rawItem in rawItems) {
    if (rawItem is! Map<String, dynamic> ||
        !rawItem.containsKey('transferId') ||
        !rawItem.containsKey('nextChunkIndex')) {
      throw const FormatException('nullable fields must be present');
    }
    final Object? status = rawItem['status'];
    if (status is! String || !statuses.contains(status)) {
      throw const FormatException('invalid status');
    }
    seen.add(status);
  }
  if (seen.length != statuses.length) {
    throw const FormatException('status fixture coverage incomplete');
  }
}
