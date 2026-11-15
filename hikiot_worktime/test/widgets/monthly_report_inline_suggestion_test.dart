import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/widgets/monthly_report_inline_suggestion.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/monthly_report_balance_fixture.dart';

MonthlyReportSnapshot snapshot({
  int value = 1040,
  String fingerprint = 'sample',
  MonthlyReportProblem? problem,
  String? unavailableReason,
  bool empty = false,
}) => MonthlyReportSnapshot(
  month: DateTime(2026, 9),
  asOf: DateTime(2026, 9, 3, 19),
  lastWorkday: DateTime(2026, 9, 30),
  bossRevision: 0,
  fingerprint: fingerprint,
  unavailableReason: unavailableReason,
  plan: unavailableReason != null
      ? null
      : MonthlyReportPlan(
          actualTotal: 3120,
          reportedTotal: problem == MonthlyReportProblem.overReported
              ? 3200
              : 0,
          remainingTotal: problem == MonthlyReportProblem.overReported
              ? -80
              : 3120,
          remainder: 0,
          pendingActual: const {'2026-09-01': 1042, '2026-09-02': 1037},
          suggestions: empty || problem != null
              ? const {}
              : {'2026-09-01': value, '2026-09-02': value},
          problem: problem,
        ),
);

class _Service extends MonthlyReportBalanceService {
  _Service(this.value);
  MonthlyReportSnapshot value;
  Future<MonthlyReportSnapshot> Function(int call)? loadResult;
  Future<bool> Function()? currentResult;
  int loads = 0;
  int checks = 0;
  bool current = true;

  @override
  Future<MonthlyReportSnapshot> load(DateTime month, {DateTime? now}) {
    loads++;
    return loadResult?.call(loads) ?? Future.value(value);
  }

  @override
  Future<bool> isCurrent(MonthlyReportSnapshot snapshot) {
    checks++;
    return currentResult?.call() ?? Future.value(current);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(
    WidgetTester tester, {
    required MonthlyReportBalanceService service,
    String date = '2026-09-01',
    void Function(MonthlyReportSnapshot, int)? onAdopt,
    Future<void> Function()? synchronize,
    String? adoptedFingerprint,
    bool enabled = true,
    ValueChanged<bool>? onAdoptingChanged,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: MonthlyReportInlineSuggestion(
                key: const ValueKey('inline'),
                date: date,
                service: service,
                onAdopt: onAdopt ?? (_, _) {},
                synchronize: synchronize,
                adoptedFingerprint: adoptedFingerprint,
                enabled: enabled,
                onAdoptingChanged: onAdoptingChanged,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('自动显示真实缓存中的本日建议及月额，不自动采用或同步网络', (tester) async {
    final fixture = MonthlyBalanceFixture();
    await fixture.seed();
    var adopts = 0;
    var synchronizes = 0;
    await open(
      tester,
      service: fixture.service,
      onAdopt: (_, _) => adopts++,
      synchronize: () async => synchronizes++,
    );
    expect(find.text('本日建议填报 10.40 小时'), findsOneWidget);
    expect(find.text('本月实际 31.20 小时'), findsOneWidget);
    expect(find.text('已填 0.00 小时'), findsOneWidget);
    expect(find.text('待分配 31.20 小时'), findsOneWidget);
    expect(adopts, 0);
    expect(synchronizes, 0);
    expect(await fixture.storage.loadBossHours('2026-09'), isEmpty);
  });

  testWidgets('明确点采用才复核并返回整数，父框确认已采用状态', (tester) async {
    final service = _Service(snapshot());
    MonthlyReportSnapshot? selected;
    int? hours;
    await open(
      tester,
      service: service,
      onAdopt: (s, h) {
        selected = s;
        hours = h;
      },
    );
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    expect(service.checks, 1);
    expect(identical(selected, service.value), isTrue);
    expect(hours, 1040);
    await open(
      tester,
      service: service,
      adoptedFingerprint: service.value.fingerprint,
    );
    expect(find.text('已采用本日建议'), findsOneWidget);
    expect(find.text('采用本日建议'), findsNothing);
    await open(tester, service: service);
    expect(find.text('采用本日建议'), findsOneWidget);
  });

  testWidgets('采用时数据已过期，不返回值并要求刷新', (tester) async {
    final service = _Service(snapshot())..current = false;
    var adopted = false;
    await open(tester, service: service, onAdopt: (_, _) => adopted = true);
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    expect(adopted, isFalse);
    expect(find.textContaining('月度建议已变化或过期'), findsOneWidget);
    expect(find.text('采用本日建议'), findsNothing);
  });

  testWidgets('父确认框忙碌时禁用新的采用及刷新入口，仍展示建议', (tester) async {
    final service = _Service(snapshot());
    await open(tester, service: service, enabled: false);
    expect(find.text('本日建议填报 10.40 小时'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '采用本日建议'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '刷新建议'))
          .onPressed,
      isNull,
    );
    expect(service.checks, 0);
  });

  testWidgets('采用期间回调父框互斥，enabled随后变false也完成当前采用再解除', (tester) async {
    final gate = Completer<bool>();
    final service = _Service(snapshot())..currentResult = () => gate.future;
    final events = <Object>[];
    var enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => MonthlyReportInlineSuggestion(
              date: '2026-09-01',
              service: service,
              enabled: enabled,
              onAdoptingChanged: (value) {
                events.add(value);
                update(() => enabled = !value);
              },
              onAdopt: (_, hours) => events.add(hours),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('采用本日建议'));
    await tester.pump();
    expect(events, [true]);
    expect(enabled, isFalse);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '刷新建议'))
          .onPressed,
      isNull,
    );
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(events, [true, 1040, false]);
    expect(enabled, isTrue);
  });

  testWidgets('采用校验异常也按true/false解除父框互斥', (tester) async {
    final gate = Completer<bool>();
    final service = _Service(snapshot())..currentResult = () => gate.future;
    final events = <bool>[];
    var adopts = 0;
    await open(
      tester,
      service: service,
      onAdopt: (_, _) => adopts++,
      onAdoptingChanged: events.add,
    );
    await tester.tap(find.text('采用本日建议'));
    await tester.pump();
    expect(events, [true]);
    gate.completeError(StateError('校验失败'));
    await tester.pumpAndSettle();
    expect(events, [true, false]);
    expect(adopts, 0);
    expect(find.textContaining('暂未确认月度建议仍有效'), findsOneWidget);
  });

  testWidgets('缺数据直接展示待确认原因，不提供采用', (tester) async {
    await open(
      tester,
      service: _Service(snapshot(unavailableReason: '请先同步考勤')),
    );
    expect(find.text('请先同步考勤'), findsOneWidget);
    expect(find.text('采用本日建议'), findsNothing);
  });

  for (final problem in MonthlyReportProblem.values) {
    testWidgets('$problem 提示手工核对，不提供采用', (tester) async {
      await open(tester, service: _Service(snapshot(problem: problem)));
      expect(find.textContaining('请手动核对已填日志'), findsOneWidget);
      expect(find.text('采用本日建议'), findsNothing);
    });
  }

  testWidgets('零建议与已填日期不提供采用', (tester) async {
    final service = _Service(snapshot(value: 0));
    await open(tester, service: service);
    expect(find.textContaining('无需提交零工时日志'), findsOneWidget);
    expect(find.text('采用本日建议'), findsNothing);
    service.value = snapshot(empty: true, fingerprint: 'filled');
    await tester.tap(find.text('刷新建议'));
    await tester.pumpAndSettle();
    expect(find.textContaining('该日期不在未填建议中'), findsOneWidget);
    expect(find.text('采用本日建议'), findsNothing);
  });

  testWidgets('只有显式刷新调用同步器，随后更新当前建议', (tester) async {
    final service = _Service(snapshot());
    var synchronizes = 0;
    await open(
      tester,
      service: service,
      synchronize: () async {
        synchronizes++;
        service.value = snapshot(value: 1050, fingerprint: 'new');
      },
    );
    expect(synchronizes, 0);
    await tester.tap(find.text('刷新建议'));
    await tester.pumpAndSettle();
    expect(synchronizes, 1);
    expect(find.text('本日建议填报 10.50 小时'), findsOneWidget);
  });

  testWidgets('工时更新通知自动重新读取，不自动采用', (tester) async {
    final fixture = MonthlyBalanceFixture();
    await fixture.seed();
    var adopts = 0;
    await open(tester, service: fixture.service, onAdopt: (_, _) => adopts++);
    await fixture.storage.saveBossHoursForDate(
      '2026-09-02',
      15,
      refreshedAt: fixture.now,
    );
    await tester.pumpAndSettle();
    expect(find.text('本日建议填报 8.10 小时'), findsOneWidget);
    expect(adopts, 0);
  });

  testWidgets('切换日期后旧读取不能覆盖新日期建议', (tester) async {
    final first = Completer<MonthlyReportSnapshot>();
    final second = Completer<MonthlyReportSnapshot>();
    final service = _Service(snapshot())
      ..loadResult = (call) => call == 1 ? first.future : second.future;
    await open(tester, service: service);
    await open(tester, service: service, date: '2026-09-02');
    second.complete(snapshot(value: 1030, fingerprint: 'new-date'));
    await tester.pumpAndSettle();
    first.complete(snapshot());
    await tester.pumpAndSettle();
    expect(find.text('本日填报建议 · 2026-09-02'), findsOneWidget);
    expect(find.text('本日建议填报 10.30 小时'), findsOneWidget);
  });

  testWidgets('读取尚未返回时离开，移除通知监听并忽略迟到读取', (tester) async {
    final gate = Completer<MonthlyReportSnapshot>();
    final service = _Service(snapshot())..loadResult = (_) => gate.future;
    await open(tester, service: service);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(snapshot());
    await tester.pumpAndSettle();
    final loads = service.loads;
    await StorageService().saveBossHours('2026-09', {});
    await tester.pumpAndSettle();
    expect(service.loads, loads);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采用校验期间离开，不回调父页面', (tester) async {
    final gate = Completer<bool>();
    final service = _Service(snapshot())..currentResult = () => gate.future;
    var adopts = 0;
    await open(tester, service: service, onAdopt: (_, _) => adopts++);
    await tester.tap(find.text('采用本日建议'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(adopts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取和显式同步异常保留刷新入口', (tester) async {
    final service = _Service(snapshot())
      ..loadResult = (_) => Future.error(StateError('读缓存失败'));
    await open(
      tester,
      service: service,
      synchronize: () => Future.error(StateError('同步失败')),
    );
    expect(find.textContaining('暂未取得本日建议'), findsOneWidget);
    await tester.tap(find.text('刷新建议'));
    await tester.pumpAndSettle();
    expect(find.text('同步未完成，请稍后刷新建议'), findsOneWidget);
    expect(find.text('刷新建议'), findsOneWidget);
  });

  testWidgets('320px双倍字体可滚动查看和采用，无布局溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _Service(snapshot());
    var adopts = 0;
    await open(tester, service: service, scale: 2, onAdopt: (_, _) => adopts++);
    await tester.ensureVisible(find.text('采用本日建议'));
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    expect(adopts, 1);
    expect(tester.takeException(), isNull);
  });
}
