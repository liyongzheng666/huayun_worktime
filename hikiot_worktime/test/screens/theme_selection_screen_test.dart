import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/theme/app_skin.dart';
import 'package:hikiot_worktime/screens/theme_selection_screen.dart';
import 'package:hikiot_worktime/services/app_theme_controller.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends StorageService {
  String? savedId;
  bool fail = false;
  @override
  Future<String?> loadAppSkinId() async => savedId;
  @override
  Future<void> saveAppSkinId(String id) async {
    if (fail) throw StateError('保存失败');
    savedId = id;
  }
}

Widget _app(AppThemeController controller, {double scale = 1}) =>
    AnimatedBuilder(
      animation: controller,
      builder: (_, _) => MaterialApp(
        theme: controller.themeData.copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ThemeSelectionScreen(controller: controller),
      ),
    );

void main() {
  final haptics = <MethodCall>[];
  Completer<void>? hapticGate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HapticUtils.setMode(HapticMode.advanced);
    haptics.clear();
    hapticGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call);
            await hapticGate?.future;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('选择主题反馈一次，当前主题无反馈且不等待触觉保存', (tester) async {
    final storage = _Storage();
    final controller = AppThemeController(storage: storage);
    hapticGate = Completer<void>();
    await tester.pumpWidget(_app(controller));
    final tile = find.byKey(const ValueKey('skin-forest'));
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(controller.current.id, 'forest');
    expect(storage.savedId, 'forest');
    expect(haptics.single.method, 'HapticFeedback.vibrate');
    expect(haptics.single.arguments, 'HapticFeedbackType.selectionClick');
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(haptics, hasLength(1));
    hapticGate!.complete();
    await tester.pump();
  });

  testWidgets('关闭震动时仍可保存主题', (tester) async {
    await HapticUtils.setMode(HapticMode.off);
    final storage = _Storage();
    final controller = AppThemeController(storage: storage);
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.byKey(const ValueKey('skin-forest')));
    await tester.pumpAndSettle();
    expect(controller.current.id, 'forest');
    expect(storage.savedId, 'forest');
    expect(haptics, isEmpty);
  });

  testWidgets('八种主题都可选择并保存，包括真实石墨深色', (tester) async {
    final storage = _Storage();
    final controller = AppThemeController(storage: storage);
    await tester.pumpWidget(_app(controller));
    for (final skin in AppSkin.all) {
      final tile = find.byKey(ValueKey('skin-${skin.id}'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(controller.current.id, skin.id);
      expect(storage.savedId, skin.id);
      expect(find.text('当前使用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('320像素窄屏双倍字号可滚动且无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppThemeController(storage: _Storage());
    await controller.select('graphite');
    await tester.pumpWidget(_app(controller, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('skin-grass')));
    await tester.tap(find.byKey(const ValueKey('skin-grass')));
    await tester.pumpAndSettle();
    expect(controller.current.id, 'grass');
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败显示恢复说明并保留原选择', (tester) async {
    final storage = _Storage()..fail = true;
    final controller = AppThemeController(storage: storage);
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.byKey(const ValueKey('skin-forest')));
    await tester.pumpAndSettle();
    expect(controller.current.id, 'grass');
    expect(find.text('这次没能记住主题，已恢复原来的选择，请再试一次。'), findsOneWidget);
  });

  test('所有主题正文与背景/卡片有足够对比，主按钮文字可读', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance();
      final y = b.computeLuminance();
      return ((x > y ? x : y) + 0.05) / ((x < y ? x : y) + 0.05);
    }

    for (final skin in AppSkin.all) {
      final colors = skin.themeData.colorScheme;
      expect(
        contrast(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(4.5),
        reason: skin.id,
      );
      expect(
        contrast(colors.onSurface, colors.surfaceContainerLow),
        greaterThanOrEqualTo(4.5),
        reason: skin.id,
      );
      expect(
        contrast(colors.onPrimary, colors.primary),
        greaterThanOrEqualTo(4.5),
        reason: skin.id,
      );
    }
    expect(AppSkin.byId('graphite')!.themeData.brightness, Brightness.dark);
  });
}
