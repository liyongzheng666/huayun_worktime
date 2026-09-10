import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/theme/app_skin.dart';
import 'package:hikiot_worktime/screens/theme_selection_screen.dart';
import 'package:hikiot_worktime/services/app_theme_controller.dart';
import 'package:hikiot_worktime/services/storage_service.dart';

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
        theme: controller.themeData,
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
