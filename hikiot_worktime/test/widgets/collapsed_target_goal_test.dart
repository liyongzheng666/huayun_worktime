import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/collapsed_target_goal.dart';

/// 把卡片推起来渲染一遍。
///
/// **必须真的渲染**：这里要防的那个 BUG（`Spacer` 放进 `Wrap`）在编译期
/// 完全合法，只有 build 到布局阶段才抛 `Incorrect use of ParentDataWidget`。
/// 而 Release 构建下它被兜成一整块纯灰的 `ErrorWidget`，本地跑 Debug 时
/// 甚至看不出异常——只断言「代码里有没有某个字符串」是拦不住的。
Future<void> pumpCard(
  WidgetTester tester, {
  int target = 120,
  double currentHours = 14.21,
  double targetHours = 12,
  bool isBaseTarget = false,
  bool isPinned = false,
  VoidCallback? onPinToggle,
  double textScale = 1.0,
  double width = 400,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SizedBox(
            width: width,
            child: CollapsedTargetGoal(
              target: target,
              currentHours: currentHours,
              targetHours: targetHours,
              isBaseTarget: isBaseTarget,
              isPinned: isPinned,
              onPinToggle: onPinToggle,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('渲染不出错', () {
    testWidgets('正常字号下能画出来', (tester) async {
      await pumpCard(tester);

      // takeException 不为 null 就说明 build/layout 抛了异常，
      // 那在 Release 里就是用户看到的那块灰色
      expect(tester.takeException(), isNull);
      expect(find.text('120% 目标已达成'), findsOneWidget);
      expect(find.text('14.21h / 12.00h'), findsOneWidget);
    });

    testWidgets('字体放大到 2 倍也不抛异常、不溢出', (tester) async {
      // 用户的系统字体就是放大的，这个 BUG 也正是「为字体放大改布局」时引入的
      await pumpCard(tester, textScale: 2.0);

      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏 + 大字体 + 全部徽章一起上也不抛异常', (tester) async {
      // 徽章越多，左边那一坨越长，越容易把右边的工时顶出去
      await pumpCard(
        tester,
        textScale: 2.0,
        width: 280,
        isBaseTarget: true,
        isPinned: true,
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('内容', () {
    testWidgets('基准目标挂「基准」徽章', (tester) async {
      await pumpCard(tester, isBaseTarget: true);

      expect(find.text('基准'), findsOneWidget);
    });

    testWidgets('非基准目标不挂徽章', (tester) async {
      await pumpCard(tester);

      expect(find.text('基准'), findsNothing);
    });

    testWidgets('置顶时显示图钉', (tester) async {
      await pumpCard(tester, isPinned: true);

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });

    testWidgets('工时按两位小数截断显示', (tester) async {
      await pumpCard(tester, currentHours: 8.567, targetHours: 8);

      expect(find.text('8.56h / 8.00h'), findsOneWidget);
    });
  });

  group('长按置顶', () {
    testWidgets('长按回调置顶切换', (tester) async {
      var toggled = false;
      await pumpCard(tester, onPinToggle: () => toggled = true);

      await tester.longPress(find.byType(CollapsedTargetGoal));
      await tester.pumpAndSettle();

      expect(toggled, isTrue);
    });

    testWidgets('没给回调时长按不报错', (tester) async {
      await pumpCard(tester);

      await tester.longPress(find.byType(CollapsedTargetGoal));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
