import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/protocol/sas_calculator.dart';

void main() {
  test('reserved Phase 2 SAS matches the shared fixed vector', () {
    final Map<String, dynamic> fixture =
        jsonDecode(
              File(
                '../protocol/fixtures/v1/valid/sas_vector.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    Uint8List bytes(String name) => Uint8List.fromList(
      base64Url.decode(base64Url.normalize(fixture[name] as String)),
    );

    expect(
      SasCalculator.calculate(
        certificateDigest: bytes('certificateSha256'),
        senderId: fixture['senderId'] as String,
        senderNonce: bytes('senderNonce'),
        receiverNonce: bytes('receiverNonce'),
        challengeId: fixture['challengeId'] as String,
      ),
      fixture['expectedSas'],
    );
  });
}
