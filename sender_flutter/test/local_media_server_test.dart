import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/local_media_server.dart';

void main() {
  test('parses all supported single range forms', () {
    expect(ByteRange.parse('bytes=10-19', 100)?.start, 10);
    expect(ByteRange.parse('bytes=10-', 100)?.endInclusive, 99);
    expect(ByteRange.parse('bytes=-20', 100)?.start, 80);
    expect(ByteRange.parse('bytes=-200', 100)?.start, 0);
    expect(ByteRange.parse('bytes=90-200', 100)?.endInclusive, 99);
  });

  test('rejects malformed and unsatisfiable ranges', () {
    for (final String value in [
      'bytes=',
      'bytes=0-1,4-5',
      'bytes=-0',
      'bytes=20-10',
      'bytes=100-',
    ]) {
      expect(
        () => ByteRange.parse(value, 100),
        throwsA(isA<MediaRangeException>()),
      );
    }
  });
}
