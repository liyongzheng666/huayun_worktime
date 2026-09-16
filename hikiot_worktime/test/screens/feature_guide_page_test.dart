import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/feature_guide_page.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HapticUtils.setMode(HapticMode.off);
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
  });

  tearDown(() {
    PlatformCapabilities.debugOverride = null;
  });

  Future<void> pumpGuide(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool showCloseButton = true,
    VoidCallback? onClose,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: FeatureGuidePage(
          showCloseButton: showCloseButton,
          onClose: onClose ?? () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> nextPage(WidgetTester tester) async {
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
  }

  Future<void> lastPage(WidgetTester tester) async {
    for (var page = 0; page < 8; page++) {
      await nextPage(tester);
    }
  }

  for (final viewport in [
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(568, 320), scale: 2.0),
    (size: const Size(320, 568), scale: 3.0),
  ]) {
    testWidgets('小屏 ${viewport.size} 字号 ${viewport.scale} 可逐页阅读且无溢出', (
      tester,
    ) async {
      await pumpGuide(tester, size: viewport.size, textScale: viewport.scale);
      for (var page = 0; page < 9; page++) {
        expect(tester.takeException(), isNull, reason: '第 ${page + 1} 页');
        final content = find.descendant(
          of: find.byType(Card).hitTestable(),
          matching: find.byType(Scrollable),
        );
        await tester.drag(content, const Offset(0, -1200));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '第 ${page + 1} 页滚动');
        if (page == 0) {
          final lastPoint = find.text('点击日期快速切换查看历史');
          await tester.ensureVisible(lastPoint);
          await tester.pumpAndSettle();
          expect(lastPoint.hitTestable(), findsOneWidget);
        }
        if (page < 8) await nextPage(tester);
      }
      expect(find.text('开始使用').hitTestable(), findsOneWidget);
    });
  }

  testWidgets('前后页按钮和左右滑动保持一致，完成回调只调用一次', (tester) async {
    var closeCalls = 0;
    await pumpGuide(tester, onClose: () => closeCalls++);
    expect(find.text('上一页'), findsNothing);
    await nextPage(tester);
    expect(find.text('月度统计').hitTestable(), findsOneWidget);
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('每日工时').hitTestable(), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(find.text('月度统计').hitTestable(), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(350, 0));
    await tester.pumpAndSettle();
    await lastPage(tester);
    await tester.tap(find.text('开始使用'));
    await tester.tap(find.text('开始使用'));
    expect(closeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭按钮连续点击只通知一次', (tester) async {
    var closeCalls = 0;
    await pumpGuide(tester, onClose: () => closeCalls++);
    await tester.tap(find.byIcon(Icons.close));
    await tester.tap(find.byIcon(Icons.close));
    expect(closeCalls, 1);
  });

  testWidgets('隐藏关闭按钮后仍可翻到最后完成', (tester) async {
    var closeCalls = 0;
    await pumpGuide(
      tester,
      showCloseButton: false,
      onClose: () => closeCalls++,
    );
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    await lastPage(tester);
    await tester.tap(find.text('开始使用'));
    expect(closeCalls, 1);
  });

  testWidgets('未提供回调时关闭只返回一层路由', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('首页')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('设置页')),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const FeatureGuidePage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS 提醒说明明确固定文案且不会自动跳过休息日', (tester) async {
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.ios();
    await pumpGuide(tester);
    await lastPage(tester);
    expect(find.textContaining('固定文案'), findsOneWidget);
    expect(find.textContaining('不会自动跳过'), findsOneWidget);
    expect(find.text('上班提醒：检测是否已打上班卡'), findsNothing);
    expect(find.text('节假日自动跳过'), findsNothing);
  });

  testWidgets('Android 提醒说明保留实时打卡信息并提示通知权限', (tester) async {
    await pumpGuide(tester);
    await lastPage(tester);
    expect(find.text('上班提醒：检测是否已打上班卡'), findsOneWidget);
    expect(find.textContaining('通知权限'), findsOneWidget);
    expect(find.textContaining('固定文案'), findsNothing);
  });

  testWidgets('刷新说明与实际支持页面和月份保持一致', (tester) async {
    await pumpGuide(tester);
    await nextPage(tester);
    await nextPage(tester);
    expect(find.text('在任意页面下拉即可刷新数据'), findsNothing);
    expect(find.textContaining('每日或月度'), findsOneWidget);
    for (var page = 2; page < 5; page++) {
      await nextPage(tester);
    }
    expect(find.text('海康API不支持按月批量获取工时'), findsNothing);
    expect(find.textContaining('所选月份'), findsOneWidget);
  });
}
