import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:lan_media_cast_sender/app_controller.dart';

void main() {
  test('oversized photo is rejected before reading the file', () async {
    bool readCalled = false;
    final PlatformFile selected = PlatformFile(
      name: 'too-large.png',
      path: 'unused',
      size: maxPhotoSourceBytes + 1,
    );

    await expectLater(
      readPhotoSourceBytes(
        selected,
        readFile: (String _) async {
          readCalled = true;
          return Uint8List(0);
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(readCalled, isFalse);
  });

  test(
    'photo preparation bounds resolution and preserves transparency',
    () async {
      final image.Image source = image.Image(
        width: 3000,
        height: 1200,
        numChannels: 4,
      )..setPixelRgba(0, 0, 255, 0, 0, 0);

      final PreparedPhoto prepared = await preparePhotoForUpload(
        Uint8List.fromList(image.encodePng(source)),
        'png',
      );

      expect(prepared.width, 2560);
      expect(prepared.height, 1024);
      expect(prepared.mime, 'image/png');
      expect(image.decodePng(prepared.bytes), isNotNull);
    },
  );

  test('opaque photos are normalized to compressed jpeg', () async {
    final image.Image source = image.Image(width: 640, height: 480);

    final PreparedPhoto prepared = await preparePhotoForUpload(
      Uint8List.fromList(image.encodeJpg(source, quality: 100)),
      'jpg',
    );

    expect(prepared.width, 640);
    expect(prepared.height, 480);
    expect(prepared.mime, 'image/jpeg');
    expect(image.decodeJpg(prepared.bytes), isNotNull);
  });
}
