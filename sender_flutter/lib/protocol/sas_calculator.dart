import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SasCalculator {
  const SasCalculator._();

  static String calculate({
    required Uint8List certificateDigest,
    required String senderId,
    required Uint8List senderNonce,
    required Uint8List receiverNonce,
    required String challengeId,
  }) {
    if (certificateDigest.length != 32 ||
        senderNonce.length != 32 ||
        receiverNonce.length != 32) {
      throw const FormatException('SAS digest and nonces must be 32 bytes');
    }
    final BytesBuilder input = BytesBuilder(copy: false)
      ..add(ascii.encode('LMC1-SAS'))
      ..add(certificateDigest)
      ..add(_uuidBytes(senderId))
      ..add(senderNonce)
      ..add(receiverNonce)
      ..add(_uuidBytes(challengeId));
    final List<int> digest = sha256.convert(input.takeBytes()).bytes;
    final int value = ByteData.sublistView(
      Uint8List.fromList(digest),
      0,
      4,
    ).getUint32(0);
    return (value % 1000000).toString().padLeft(6, '0');
  }

  static Uint8List _uuidBytes(String uuid) {
    final String compact = uuid.replaceAll('-', '');
    if (compact.length != 32) throw const FormatException('Invalid UUID');
    return Uint8List.fromList(
      List<int>.generate(
        16,
        (int index) =>
            int.parse(compact.substring(index * 2, index * 2 + 2), radix: 16),
      ),
    );
  }
}
