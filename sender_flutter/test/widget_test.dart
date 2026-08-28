import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lan_media_cast_sender/main.dart';
import 'package:lan_media_cast_sender/services/cast_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('application exposes a bounded initialization state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LanMediaCastApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('sender controls do not overflow a 360 pixel viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    await tester.pumpWidget(const LanMediaCastApp());
    for (int attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(SenderScreen).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(SenderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sender survives status and responsive layout transitions', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    await tester.pumpWidget(const LanMediaCastApp());
    for (int attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(SenderScreen).evaluate().isNotEmpty) break;
    }
    final SenderScreen screen = tester.widget<SenderScreen>(
      find.byType(SenderScreen),
    );
    await tester.pump(const Duration(seconds: 3));
    screen.controller
      ..statusMessage = '可复制的连接错误'
      ..statusIsError = true
      ..notifyListeners();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('错误详情'), findsOneWidget);
    expect(find.text('可复制的连接错误'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.text('可复制的连接错误'), findsNothing);

    tester.view.physicalSize = const Size(700, 720);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1200, 720);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('sender ignores an in-flight scan after controller disposal', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    await tester.pumpWidget(const LanMediaCastApp());
    for (int attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(SenderScreen).evaluate().isNotEmpty) break;
    }
    final SenderScreen screen = tester.widget<SenderScreen>(
      find.byType(SenderScreen),
    );

    screen.controller.dispose();
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('pairing dialog tolerates its connection being disposed', (
    WidgetTester tester,
  ) async {
    final CastConnection connection = CastConnection(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
    );
    await tester.pumpWidget(
      MaterialApp(home: PairingDialog(connection: connection)),
    );

    connection.dispose();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
