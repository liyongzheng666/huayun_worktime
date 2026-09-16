import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/pull_refresh_guide.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(568, 270)]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('引导 ${size.width}x${size.height} 字号$scale 无溢出且可关闭', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var closed = false;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Stack(
                children: [PullRefreshGuide(onCompleted: () => closed = true)],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        final button = tester.getRect(find.byType(ElevatedButton));
        expect(button.bottom, lessThanOrEqualTo(size.height));
        await tester.tap(find.text('我知道了'));
        expect(closed, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('我知道了可点击，提示卡和手势图案不拦截底层下拉', (tester) async {
    var completed = 0;
    var drags = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (_) => drags++,
                  child: const SizedBox.expand(),
                ),
              ),
              PullRefreshGuide(onCompleted: () => completed++),
            ],
          ),
        ),
      ),
    );
    for (final decoration in [
      find.text('向下拉动页面即可刷新数据'),
      find.byIcon(Icons.touch_app),
    ]) {
      final previousDrags = drags;
      await tester.dragFrom(tester.getCenter(decoration), const Offset(0, 150));
      await tester.pump();
      expect(drags, greaterThan(previousDrags));
    }
    await tester.tap(find.text('我知道了'));
    expect(completed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
