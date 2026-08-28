import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';

void main() {
  test('media action leaves photo mode before playback', () async {
    bool photoMode = true;
    final List<String> calls = <String>[];

    await runMediaAction(
      isPhotoMode: () => photoMode,
      leavePhotoMode: () async {
        calls.add('mode.set:media');
        photoMode = false;
      },
      action: () async => calls.add('player.select'),
    );

    expect(calls, <String>['mode.set:media', 'player.select']);
  });

  test('media action stops when photo mode could not be left', () async {
    bool photoMode = true;
    final List<String> calls = <String>[];

    await runMediaAction(
      isPhotoMode: () => photoMode,
      leavePhotoMode: () async => calls.add('mode.set:media'),
      action: () async => calls.add('player.select'),
    );

    expect(photoMode, isTrue);
    expect(calls, <String>['mode.set:media']);
  });
}
