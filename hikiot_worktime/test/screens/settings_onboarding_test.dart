import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/storage_keys.dart';
import 'package:hikiot_worktime/screens/settings_screen.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('重新体验保存未完成状态后通知主框架立即返回引导', (tester) async {
    SharedPreferences.setMockInitialValues({
      StorageKeys.onboardingCompleted: true,
    });
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.ios();
    addTearDown(() => PlatformCapabilities.debugOverride = null);
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    bool? completedAtCallback;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          onRestartOnboarding: () {
            calls++;
            completedAtCallback = prefs.getBool(
              StorageKeys.onboardingCompleted,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('重新体验新手引导'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新体验新手引导'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(completedAtCallback, isFalse);
    expect(await StorageService().loadOnboardingCompleted(), isFalse);
    expect(find.textContaining('重启本应用'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
