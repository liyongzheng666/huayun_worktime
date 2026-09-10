import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/widgets/today_wrap_up_card.dart';

TodayWrapUpSummary summary({
  TodayWrapUpItemStatus submissionStatus = TodayWrapUpItemStatus.unknown,
  TodayWrapUpAction action = TodayWrapUpAction.refresh,
}) {
  return TodayWrapUpSummary(
    title: '☕ 今天辛苦啦',
    subtitle: '先看一眼今天的状态，再轻轻松松收尾。',
    attendance: const TodayWrapUpItem(
      label: '考勤',
      detail: '今日工时 8.56 小时',
      status: TodayWrapUpItemStatus.complete,
    ),
    csv: const TodayWrapUpItem(
      label: '日志素材',
      detail: '今天的内容已准备好',
      status: TodayWrapUpItemStatus.complete,
    ),
    submission: TodayWrapUpItem(
      label: 'BOSS 提交',
      detail: submissionStatus == TodayWrapUpItemStatus.complete
          ? '已确认提交成功'
          : '等待确认，稍后刷新看看',
      status: submissionStatus,
    ),
    primaryAction: action,
    actionLabel: '检查今日状态',
  );
}

Future<void> pumpCard(
  WidgetTester tester, {
  TodayWrapUpSummary? data,
  ValueChanged<TodayWrapUpAction>? onAction,
  VoidCallback? onRefresh,
  bool isRefreshing = false,
  double width = 390,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TodayWrapUpCard(
                  summary: data ?? summary(),
                  onAction: onAction ?? (_) {},
                  onRefresh: onRefresh,
                  isRefreshing: isRefreshing,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('未确认的提交显示问号，不会和已完成项一起画成绿勾', (tester) async {
    await pumpCard(tester);

    expect(find.text('今日收尾'), findsOneWidget);
    expect(find.textContaining('等待确认', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
  });

  testWidgets('已确认提交显示完成状态', (tester) async {
    await pumpCard(
      tester,
      data: summary(submissionStatus: TodayWrapUpItemStatus.complete),
    );

    expect(find.textContaining('已确认提交成功', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
  });

  testWidgets('每一种主操作都原样交还页面处理', (tester) async {
    for (final action in TodayWrapUpAction.values) {
      TodayWrapUpAction? received;
      await pumpCard(
        tester,
        data: summary(action: action),
        onAction: (value) => received = value,
      );
      await tester.tap(find.byType(FilledButton));
      expect(received, action);
    }
  });

  testWidgets('刷新独立触发，不会误调用主操作', (tester) async {
    var refreshCount = 0;
    var actionCount = 0;
    await pumpCard(
      tester,
      onRefresh: () => refreshCount++,
      onAction: (_) => actionCount++,
    );

    await tester.tap(find.byTooltip('刷新今日状态'));
    expect(refreshCount, 1);
    expect(actionCount, 0);
  });

  testWidgets('刷新中仍能读三项状态并防止重复操作', (tester) async {
    var count = 0;
    await pumpCard(
      tester,
      isRefreshing: true,
      onRefresh: () => count++,
      onAction: (_) => count++,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('考勤', findRichText: true), findsOneWidget);
    expect(find.textContaining('日志素材', findRichText: true), findsOneWidget);
    expect(find.textContaining('BOSS 提交', findRichText: true), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byType(FilledButton));
    expect(count, 0);
  });

  testWidgets('休息日使用中性状态，不制造缺卡提醒', (tester) async {
    const neutralItem = TodayWrapUpItem(
      label: '考勤',
      detail: '今天休息，好好充电',
      status: TodayWrapUpItemStatus.neutral,
    );
    await pumpCard(
      tester,
      data: TodayWrapUpSummary(
        title: '🌿 今天慢一点也没关系',
        subtitle: '按实际安排处理即可。',
        attendance: neutralItem,
        csv: neutralItem,
        submission: neutralItem,
        primaryAction: TodayWrapUpAction.viewLog,
        actionLabel: '查看日志',
      ),
    );

    expect(find.byIcon(Icons.remove_circle_outline_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('320 宽、两倍字号、${brightness.name} 主题无溢出', (tester) async {
      await pumpCard(
        tester,
        width: 320,
        textScale: 2,
        brightness: brightness,
        onRefresh: () {},
      );

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(FilledButton));
      expect(tester.takeException(), isNull);
    });
  }
}
