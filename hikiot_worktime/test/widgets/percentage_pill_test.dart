import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/percentage_pill.dart';

void main() {
  group('完成度配色分档', () {
    test('不到 100% 为橙色', () {
      expect(PercentagePill.colorFor(0), const Color(0xFFEF6C00));
      expect(PercentagePill.colorFor(53.12), const Color(0xFFEF6C00));
      expect(PercentagePill.colorFor(99.99), const Color(0xFFEF6C00));
    });

    test('100% 到 140% 为绿色', () {
      // 100% 是「干够了」的分界，必须落在绿区而不是橙区
      expect(PercentagePill.colorFor(100), const Color(0xFF2E7D32));
      expect(PercentagePill.colorFor(120), const Color(0xFF2E7D32));
      expect(PercentagePill.colorFor(140), const Color(0xFF2E7D32));
    });

    test('超过 140% 为红色', () {
      expect(PercentagePill.colorFor(140.01), const Color(0xFFD32F2F));
      expect(PercentagePill.colorFor(180), const Color(0xFFD32F2F));
    });

    test('140% 本身不算超时，超过才算', () {
      // 边界取「超过」而非「达到」，避免刚好卡线就开始闪
      expect(PercentagePill.isOverwork(140), isFalse);
      expect(PercentagePill.isOverwork(140.01), isTrue);
    });
  });

  group('闪烁行为', () {
    // 不套 MaterialApp：它的路由本身就带多层 FadeTransition，
    // 而且都是文字的祖先，会让「有没有闪烁」无从判断。
    Widget wrap(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    );

    Finder blinkOf(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(FadeTransition),
    );

    testWidgets('未超时不启动动画，胶囊静态显示', (tester) async {
      await tester.pumpWidget(wrap(const PercentagePill(percentage: 120)));

      expect(find.text('120.00%'), findsOneWidget);
      expect(blinkOf('120.00%'), findsNothing);
      // 没有常驻动画时 pumpAndSettle 才能收敛
      await tester.pumpAndSettle();
    });

    testWidgets('超时后套上淡入淡出，且文字始终在树上', (tester) async {
      await tester.pumpWidget(wrap(const PercentagePill(percentage: 160)));

      expect(blinkOf('160.00%'), findsOneWidget);

      // 闪烁期间文字不能消失——整块隐藏会让行高来回跳，看着像故障
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('160.00%'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('160.00%'), findsOneWidget);
    });

    testWidgets('工时涨过阈值时开始闪烁', (tester) async {
      // 工时随时间增长，可能在页面存续期间跨过 140%
      await tester.pumpWidget(wrap(const PercentagePill(percentage: 130)));
      expect(blinkOf('130.00%'), findsNothing);

      await tester.pumpWidget(wrap(const PercentagePill(percentage: 150)));
      await tester.pump();
      expect(blinkOf('150.00%'), findsOneWidget);
    });
  });
}
