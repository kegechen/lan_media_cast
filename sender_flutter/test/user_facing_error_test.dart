import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/user_facing_error.dart';

void main() {
  test('translates command timeout and retains its diagnostic detail', () {
    final String message = userFacingError(
      TimeoutException('Future not completed'),
    );

    expect(message, contains('操作超时'));
    expect(message, contains('Future not completed'));
  });

  test('translates a disconnected socket and keeps the system detail', () {
    final String message = userFacingError(
      const SocketException('Connection reset by peer'),
    );

    expect(message, contains('网络连接已中断'));
    expect(message, contains('Connection reset by peer'));
  });
}
