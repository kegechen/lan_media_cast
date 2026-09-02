import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/protocol/protocol.dart';

void main() {
  test('decodes a receiver log chunk response', () {
    final ReceiverLogChunk chunk = ReceiverLogChunk.fromPayload({
      'ok': true,
      'format': 'text',
      'offset': 0,
      'nextOffset': 8,
      'totalBytes': 8,
      'eof': true,
      'data': 'line 1\n',
    });
    expect(chunk.offset, 0);
    expect(chunk.nextOffset, 8);
    expect(chunk.totalBytes, 8);
    expect(chunk.eof, isTrue);
    expect(chunk.data, 'line 1\n');
  });

  test('rejects malformed receiver log chunk responses', () {
    expect(
      () => ReceiverLogChunk.fromPayload({
        'ok': true,
        'format': 'text',
        'offset': 8,
        'nextOffset': 7,
        'totalBytes': 8,
        'eof': false,
        'data': 'bad',
      }),
      throwsFormatException,
    );
  });
}
