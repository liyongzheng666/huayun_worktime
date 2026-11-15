import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/widgets/month_end_report_review_dialog.dart';

MonthlyReportSnapshot _snapshot({
  int actual = 3120,
  int reported = 3000,
  String? reason,
  bool noPending = false,
  MonthlyReportProblem? problem,
  String fingerprint = 'snapshot',
}) => MonthlyReportSnapshot(
  month: DateTime(2026, 11),
  asOf: DateTime(2026, 11, 30, 19),
  lastWorkday: DateTime(2026, 11, 30),
  bossRevision: 1,
  fingerprint: fingerprint,
  unavailableReason: reason,
  plan: MonthlyReportPlan(
    actualTotal: actual,
    reportedTotal: reported,
    remainingTotal: actual - reported,
    remainder: actual >= reported ? (actual - reported) % 10 : 0,
    pendingActual: noPending ? const {} : const {'2026-11-30': 1040},
    suggestions: const {},
    problem: problem,
  ),
);

class _Answer {
  MonthlyReportSnapshot? value;
  bool returned = false;
}

Future<_Answer> _open(
  WidgetTester tester,
  MonthlyReportSnapshot snapshot, {
  Future<MonthlyReportSnapshot> Function()? onRefresh,
  Future<bool> Function(MonthlyReportSnapshot)? validate,
  double textScale = 1,
}) async {
  final answer = _Answer();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              answer.value = await MonthEndReportReviewDialog.show(
                context: context,
                snapshot: snapshot,
                onRefresh: onRefresh,
                validate: validate,
              );
              answer.returned = true;
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('少填提示显示应填已填及精确差值，明确核对后才返回', (tester) async {
    final snapshot = _snapshot();
    final answer = await _open(tester, snapshot);
    expect(find.text('本月填报差额核对'), findsOneWidget);
    expect(find.text('基于已同步考勤和华天数据'), findsOneWidget);
    expect(find.text('31.20 小时'), findsOneWidget);
    expect(find.text('30.00 小时'), findsOneWidget);
    expect(find.text('少填 1.20 小时'), findsOneWidget);
    expect(find.textContaining('核对未填日期'), findsOneWidget);
    expect(find.text('确认提交'), findsNothing);
    expect(answer.returned, isFalse);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.value, same(snapshot));
    expect(answer.returned, isTrue);
  });

  testWidgets('多填明确方向且问题计划仍可确认查看结果', (tester) async {
    final snapshot = _snapshot(
      reported: 3200,
      problem: MonthlyReportProblem.overReported,
    );
    final answer = await _open(tester, snapshot, validate: (_) async => true);
    expect(find.text('多填 0.80 小时'), findsOneWidget);
    expect(find.textContaining('手动编辑已填日报'), findsOneWidget);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.value, same(snapshot));
  });

  testWidgets('差额零也明确核对，不隐去应填和已填', (tester) async {
    final snapshot = _snapshot(actual: 1020, reported: 1020, noPending: true);
    final answer = await _open(tester, snapshot);
    expect(find.text('10.20 小时'), findsNWidgets(2));
    expect(find.text('一致，差额 0.00 小时'), findsOneWidget);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.value, same(snapshot));
  });

  testWidgets('无未填日期仍有差额时提示手动核对，不阻止确认已看结果', (tester) async {
    final answer = await _open(
      tester,
      _snapshot(noPending: true, problem: MonthlyReportProblem.noPendingDates),
    );
    expect(find.textContaining('已没有未填日期'), findsOneWidget);
    expect(find.text('少填 1.20 小时'), findsOneWidget);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.value, isNotNull);
  });

  testWidgets('旧计划不可信时三项待确认，不把未知当作零', (tester) async {
    final answer = await _open(tester, _snapshot(reason: '华天确认已过期，请重新同步'));
    expect(find.text('待确认'), findsNWidgets(3));
    expect(find.text('31.20 小时'), findsNothing);
    expect(find.text('一致，差额 0.00 小时'), findsNothing);
    expect(find.text('华天确认已过期，请重新同步'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '我已核对'))
          .onPressed,
      isNull,
    );
    expect(answer.returned, isFalse);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
    expect(answer.value, isNull);
    expect(answer.returned, isTrue);
  });

  testWidgets('刷新只在点击时调用，新快照经校验后返回', (tester) async {
    final fresh = _snapshot(reported: 3120, fingerprint: 'fresh');
    final gate = Completer<MonthlyReportSnapshot>();
    var refreshes = 0;
    final validations = <MonthlyReportSnapshot>[];
    final answer = await _open(
      tester,
      _snapshot(reason: '需要同步'),
      onRefresh: () {
        refreshes++;
        return gate.future;
      },
      validate: (value) async {
        validations.add(value);
        return true;
      },
    );
    expect(refreshes, 0);
    await tester.tap(find.text('刷新核对'));
    await tester.pump();
    expect(refreshes, 1);
    expect(find.text('正在刷新…'), findsOneWidget);
    gate.complete(fresh);
    await tester.pumpAndSettle();
    expect(find.text('一致，差额 0.00 小时'), findsOneWidget);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.value, same(fresh));
    expect(validations, [fresh]);
  });

  testWidgets('刷新失败保留为未知，不能确认旧数据', (tester) async {
    final answer = await _open(
      tester,
      _snapshot(),
      onRefresh: () async => throw StateError('network unavailable'),
    );
    await tester.tap(find.text('刷新核对'));
    await tester.pumpAndSettle();
    expect(find.text('待确认'), findsNWidgets(3));
    expect(find.textContaining('刷新未完成'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '我已核对'))
          .onPressed,
      isNull,
    );
    expect(answer.returned, isFalse);
  });

  testWidgets('确认时已过期需刷新，不结束核对或显示旧数额', (tester) async {
    final answer = await _open(
      tester,
      _snapshot(),
      validate: (_) async => false,
    );
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.returned, isFalse);
    expect(find.textContaining('核对数据已变化或过期'), findsOneWidget);
    expect(find.text('待确认'), findsNWidgets(3));
  });

  testWidgets('刷新期间取消，迟到结果不更新已退出页面', (tester) async {
    final gate = Completer<MonthlyReportSnapshot>();
    final answer = await _open(
      tester,
      _snapshot(),
      onRefresh: () => gate.future,
    );
    await tester.tap(find.text('刷新核对'));
    await tester.pump();
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
    gate.complete(_snapshot(fingerprint: 'late'));
    await tester.pumpAndSettle();
    expect(answer.value, isNull);
    expect(answer.returned, isTrue);
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('校验期间返回，迟到结果不能再次关闭父页面', (tester) async {
    final gate = Completer<bool>();
    final answer = await _open(
      tester,
      _snapshot(),
      validate: (_) => gate.future,
    );
    await tester.tap(find.text('我已核对'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(answer.value, isNull);
    expect(answer.returned, isTrue);
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('校验异常给出待核对提示，不泄露异常或确认旧值', (tester) async {
    final answer = await _open(
      tester,
      _snapshot(),
      validate: (_) async => throw StateError('private diagnostic details'),
    );
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(answer.returned, isFalse);
    expect(find.textContaining('暂未确认核对数据仍有效'), findsOneWidget);
    expect(find.textContaining('private diagnostic details'), findsNothing);
  });

  testWidgets('320px双倍字体可滚动核对，操作不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(
      tester,
      _snapshot(),
      textScale: 2,
      onRefresh: () async => _snapshot(),
    );
    expect(tester.takeException(), isNull);
    final footer = find.textContaining('此处只确认查看结果');
    await tester.ensureVisible(footer);
    expect(tester.takeException(), isNull);
    expect(find.text('我已核对'), findsOneWidget);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
  });
}
