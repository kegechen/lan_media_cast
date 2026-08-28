import 'dart:typed_data';

const int photoChunkHeaderSize = 32;
const int maxPhotoChunkPayloadBytes = 64 * 1024;

class PhotoChunkFrame {
  const PhotoChunkFrame({
    required this.transferId,
    required this.chunkIndex,
    required this.last,
    required this.payload,
  });

  final String transferId;
  final int chunkIndex;
  final bool last;
  final Uint8List payload;

  Uint8List encode() {
    if (chunkIndex < 0 || chunkIndex > 0xffffffff) {
      throw const FormatException('chunkIndex is outside uint32');
    }
    if (payload.length > maxPhotoChunkPayloadBytes) {
      throw const FormatException('Photo chunk payload is too large');
    }
    final Uint8List output = Uint8List(photoChunkHeaderSize + payload.length);
    output.setAll(0, <int>[0x4c, 0x4d, 0x43, 0x31, 0x01, 0x10]);
    final ByteData header = ByteData.sublistView(output);
    header.setUint16(6, last ? 1 : 0, Endian.big);
    output.setAll(8, _uuidBytes(transferId));
    header.setUint32(24, chunkIndex, Endian.big);
    header.setUint32(28, payload.length, Endian.big);
    output.setAll(photoChunkHeaderSize, payload);
    return output;
  }

  static PhotoChunkFrame decode(Uint8List bytes) {
    if (bytes.length < photoChunkHeaderSize) {
      throw const FormatException('Photo chunk header is truncated');
    }
    final ByteData header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.big) != 0x4c4d4331 ||
        header.getUint8(4) != 1 ||
        header.getUint8(5) != 0x10) {
      throw const FormatException('Photo chunk signature is invalid');
    }
    final int flags = header.getUint16(6, Endian.big);
    if ((flags & ~1) != 0) {
      throw const FormatException('Photo chunk flags are invalid');
    }
    final int payloadLength = header.getUint32(28, Endian.big);
    if (payloadLength > maxPhotoChunkPayloadBytes ||
        bytes.length != photoChunkHeaderSize + payloadLength) {
      throw const FormatException('Photo chunk length is invalid');
    }
    return PhotoChunkFrame(
      transferId: _formatUuid(bytes.sublist(8, 24)),
      chunkIndex: header.getUint32(24, Endian.big),
      last: flags == 1,
      payload: Uint8List.sublistView(bytes, photoChunkHeaderSize),
    );
  }

  static Uint8List _uuidBytes(String uuid) {
    final String compact = uuid.replaceAll('-', '');
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
      throw const FormatException('transferId is not a UUID');
    }
    return Uint8List.fromList(
      List<int>.generate(
        16,
        (int index) =>
            int.parse(compact.substring(index * 2, index * 2 + 2), radix: 16),
      ),
    );
  }

  static String _formatUuid(List<int> bytes) {
    final String compact = bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${compact.substring(0, 8)}-'
        '${compact.substring(8, 12)}-'
        '${compact.substring(12, 16)}-'
        '${compact.substring(16, 20)}-'
        '${compact.substring(20)}';
  }
}
