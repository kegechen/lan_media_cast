import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/protocol/photo_chunk.dart';

void main() {
  final File fixtureFile = File(
    '../protocol/fixtures/v1/valid/photo_chunk_frame.json',
  );
  final File boundaryFixtureFile = File(
    '../protocol/fixtures/v1/valid/photo_chunk_boundaries.json',
  );

  test('photo chunk encoding matches the shared fixed fixture', () {
    final Map<String, dynamic> fixture =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final PhotoChunkFrame frame = PhotoChunkFrame(
      transferId: fixture['transferId'] as String,
      chunkIndex: fixture['chunkIndex'] as int,
      last: fixture['last'] as bool,
      payload: _decodeHex(fixture['payloadHex'] as String),
    );

    expect(_encodeHex(frame.encode()), fixture['frameHex']);
    final PhotoChunkFrame decoded = PhotoChunkFrame.decode(frame.encode());
    expect(decoded.transferId, frame.transferId);
    expect(decoded.chunkIndex, frame.chunkIndex);
    expect(decoded.last, isTrue);
    expect(decoded.payload, frame.payload);
  });

  test('photo chunk decoder rejects malformed structure', () {
    final Uint8List valid = _decodeHex(
      (jsonDecode(fixtureFile.readAsStringSync())
              as Map<String, dynamic>)['frameHex']
          as String,
    );
    for (final Uint8List invalid in <Uint8List>[
      Uint8List.sublistView(valid, 0, 31),
      Uint8List.fromList(valid)..[0] = 0,
      Uint8List.fromList(valid)..[7] = 2,
      Uint8List.sublistView(valid, 0, valid.length - 1),
    ]) {
      expect(() => PhotoChunkFrame.decode(invalid), throwsFormatException);
    }
  });

  test('photo chunk boundary vectors decode consistently', () {
    final Map<String, dynamic> fixture =
        jsonDecode(boundaryFixtureFile.readAsStringSync())
            as Map<String, dynamic>;
    final List<dynamic> cases = fixture['cases'] as List<dynamic>;
    for (final dynamic rawCase in cases) {
      final Map<String, dynamic> boundary = rawCase as Map<String, dynamic>;
      final Uint8List encoded = _decodeHex(boundary['frameHex'] as String);
      final PhotoChunkFrame decoded = PhotoChunkFrame.decode(encoded);
      expect(decoded.transferId, fixture['transferId']);
      expect(decoded.chunkIndex, boundary['chunkIndex']);
      expect(decoded.payload, <int>[0xaa]);
    }
    expect(
      () => PhotoChunkFrame.decode(
        _decodeHex(fixture['malformedHeaderHex'] as String),
      ),
      throwsFormatException,
    );
  });
}

Uint8List _decodeHex(String value) => Uint8List.fromList(
  List<int>.generate(
    value.length ~/ 2,
    (int index) =>
        int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
  ),
);

String _encodeHex(List<int> bytes) =>
    bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
