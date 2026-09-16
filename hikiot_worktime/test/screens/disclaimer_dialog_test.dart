import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/disclaimer_dialog.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openDisclaimer(
    WidgetTester tester, {
    required VoidCallback onConfirmed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  DisclaimerDialog.showIfNeeded(context, onConfirmed),
              child: const Text('启动'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('启动'));
    await tester.pumpAndSettle();
  }

  testWidgets('首次启动的系统返回不能跳过同意并留下不可恢复的启动页', (tester) async {
    var confirmed = 0;
    await openDisclaimer(tester, onConfirmed: () => confirmed++);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('免责声明'), findsOneWidget);
    expect(confirmed, 0);
    expect(await StorageService().loadDisclaimerAccepted(), isFalse);

    await tester.tap(find.text('我已知晓并同意'));
    await tester.pumpAndSettle();
    expect(find.text('免责声明'), findsNothing);
    expect(confirmed, 1);
    expect(await StorageService().loadDisclaimerAccepted(), isTrue);
  });

  testWidgets('快速重复同意只推进一次启动导航', (tester) async {
    var confirmed = 0;
    await openDisclaimer(tester, onConfirmed: () => confirmed++);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '我已知晓并同意'),
    );

    // 两次事件都先于本地保存完成，覆盖双击导致重复 pop/启动导航的情况。
    button.onPressed!();
    button.onPressed!();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(confirmed, 1);
    expect(find.text('启动'), findsOneWidget);
    expect(await StorageService().loadDisclaimerAccepted(), isTrue);
  });

  testWidgets('已经同意的再次启动直接继续', (tester) async {
    await StorageService().saveDisclaimerAccepted(true);
    var confirmed = 0;
    await openDisclaimer(tester, onConfirmed: () => confirmed++);

    expect(find.text('免责声明'), findsNothing);
    expect(confirmed, 1);
  });
}
