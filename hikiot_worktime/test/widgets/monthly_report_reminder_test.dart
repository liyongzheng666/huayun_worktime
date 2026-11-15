import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/widgets/monthly_report_reminder.dart';
import 'package:shared_preferences/shared_preferences.dart';

MonthlyReportSnapshot snapshot({
  DateTime? asOf,
  String fingerprint = 'first',
  String? unavailableReason,
  MonthlyReportPlan? plan,
}) => MonthlyReportSnapshot(
  month: DateTime(2026, 10),
  asOf: asOf ?? DateTime(2026, 10, 31, 20),
  lastWorkday: DateTime(2026, 10, 31),
  bossRevision: 0,
  fingerprint: fingerprint,
  unavailableReason: unavailableReason,
  plan: unavailableReason != null
      ? null
      : plan ??
            MonthlyReportBalance.calculate(
              actualByDate: {'2026-10-01': 1006},
              reportedByDate: {},
            ),
);

class _Service extends MonthlyReportBalanceService {
  MonthlyReportSnapshot value = snapshot();
  final months = <DateTime>[];
  Future<MonthlyReportSnapshot> Function()? respond;

  @override
  DateTime get now => DateTime(2026, 10, 31, 20);

  @override
  Future<MonthlyReportSnapshot> load(DateTime month, {DateTime? now}) async {
    months.add(month);
    return respond == null ? value : await respond!();
  }
}

class _Child extends StatefulWidget {
  const _Child();
  static int starts = 0;

  @override
  State<_Child> createState() => _ChildState();
}

class _ChildState extends State<_Child> {
  @override
  void initState() {
    super.initState();
    _Child.starts++;
  }

  @override
  Widget build(BuildContext context) => const Text('原有页面');
}

void main() {
  late _Service service;
  late GlobalKey<MonthlyReportReminderState> key;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = _Service();
    key = GlobalKey<MonthlyReportReminderState>();
    _Child.starts = 0;
  });

  Future<void> open(
    WidgetTester tester, {
    Future<void> Function(MonthlyReportSnapshot)? review,
    TextScaler? textScaler,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: Scaffold(
          body: MonthlyReportReminder(
            key: key,
            service: service,
            onReview: review,
            child: const _Child(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('打开App按注入时钟的当月读取，只展示尾差，不自动打开对话框', (tester) async {
    await open(tester);
    expect(service.months, [service.now]);
    expect(find.text('月底填报核对'), findsOneWidget);
    expect(find.textContaining('0.06 小时尾差'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('原有页面'), findsOneWidget);
  });

  testWidgets('未到最后工作日时隐藏，出现与关闭提示均保留原有页面状态', (tester) async {
    service.value = snapshot(asOf: DateTime(2026, 10, 30));
    await open(tester);
    expect(find.text('月底填报核对'), findsNothing);
    expect(_Child.starts, 1);
    service.value = snapshot();
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.text('月底填报核对'), findsOneWidget);
    expect(_Child.starts, 1);
    await tester.tap(find.text('本次关闭'));
    await tester.pumpAndSettle();
    expect(find.text('月底填报核对'), findsNothing);
    expect(_Child.starts, 1);
  });

  testWidgets('数据未知时显示需要同步，不把未知冒充没有差额', (tester) async {
    service.value = snapshot(unavailableReason: '华天状态待确认，请同步本月工时');
    await open(tester);
    expect(find.text('月底填报核对'), findsOneWidget);
    expect(find.text('华天状态待确认，请同步本月工时'), findsOneWidget);
    expect(find.textContaining('可舍弃'), findsNothing);
  });

  testWidgets('已经超报与没有未填日期时显示具体差额和手工处理说明', (tester) async {
    service.value = snapshot(
      plan: MonthlyReportBalance.calculate(
        actualByDate: {'2026-10-01': 1000},
        reportedByDate: {'2026-10-01': 1050},
      ),
    );
    await open(tester);
    expect(find.textContaining('比实际多 0.50 小时'), findsOneWidget);
    expect(find.textContaining('手动编辑已填日志'), findsOneWidget);
    service.value = snapshot(
      fingerprint: 'under',
      plan: MonthlyReportBalance.calculate(
        actualByDate: {'2026-10-01': 1000},
        reportedByDate: {'2026-10-01': 950},
      ),
    );
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.textContaining('已没有未填日期，仍有 0.50 小时差额'), findsOneWidget);
  });

  testWidgets('待填额度只能分配零工时时提示核对已有日志并保留尾差信息', (tester) async {
    service.value = snapshot(
      plan: MonthlyReportBalance.calculate(
        actualByDate: {'2026-10-01': 1000, '2026-10-02': 1000},
        reportedByDate: {'2026-10-01': 2000},
      ),
    );
    await open(tester);
    expect(find.textContaining('部分未填日期建议为 0.00 小时'), findsOneWidget);
    expect(find.textContaining('无需提交零工时日志'), findsOneWidget);
    service.value = snapshot(
      fingerprint: 'zero-with-remainder',
      plan: MonthlyReportBalance.calculate(
        actualByDate: {'2026-10-01': 1000, '2026-10-02': 1006},
        reportedByDate: {'2026-10-01': 2000},
      ),
    );
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.textContaining('尚余 0.06 小时尾差'), findsOneWidget);
    expect(find.textContaining('月底不足 0.10 小时的部分可舍弃'), findsOneWidget);
  });

  testWidgets('返回前台与工时缓存变化都会重读，关闭只影响当前快照', (tester) async {
    await open(tester);
    await tester.tap(find.text('本次关闭'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.months, hasLength(2));
    expect(find.text('月底填报核对'), findsNothing);
    service.value = snapshot(fingerprint: 'changed');
    await StorageService().saveBossHoursForDate('2026-10-01', 9.0);
    await tester.pumpAndSettle();
    expect(service.months, hasLength(3));
    expect(find.text('月底填报核对'), findsOneWidget);
  });

  testWidgets('查看建议前重新读取，只把新快照交给预览回调', (tester) async {
    MonthlyReportSnapshot? reviewed;
    await open(tester, review: (value) async => reviewed = value);
    service.value = snapshot(fingerprint: 'new');
    await tester.tap(find.text('查看建议'));
    await tester.pumpAndSettle();
    expect(reviewed?.fingerprint, 'new');
    expect(service.months, hasLength(2));
    expect(await StorageService().loadBossHours('2026-10'), isEmpty);
  });

  testWidgets('查看期间另有刷新时，不用被淘汰的结果打开旧建议', (tester) async {
    var reviews = 0;
    await open(tester, review: (_) async => reviews++);
    final reviewRead = Completer<MonthlyReportSnapshot>();
    final newRead = Completer<MonthlyReportSnapshot>();
    var calls = 0;
    service.respond = () => calls++ == 0 ? reviewRead.future : newRead.future;
    await tester.tap(find.text('查看建议'));
    await tester.pump();
    final newer = key.currentState!.refresh();
    reviewRead.complete(snapshot());
    await tester.pumpAndSettle();
    expect(reviews, 0);
    newRead.complete(snapshot(fingerprint: 'newest'));
    await newer;
    await tester.pumpAndSettle();
    expect(find.text('月底填报核对'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('迟到读取不能覆盖较新的结果，销毁后完成读取也不更新页面', (tester) async {
    final first = Completer<MonthlyReportSnapshot>();
    final second = Completer<MonthlyReportSnapshot>();
    var calls = 0;
    service.respond = () => calls++ == 0 ? first.future : second.future;
    await open(tester);
    final refresh = key.currentState!.refresh();
    expect(calls, 1);
    first.complete(snapshot());
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('0.06 小时尾差'), findsNothing);
    second.complete(snapshot(unavailableReason: '最新状态待同步'));
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('最新状态待同步'), findsOneWidget);
    expect(find.textContaining('0.06 小时尾差'), findsNothing);

    final pending = Completer<MonthlyReportSnapshot>();
    service.respond = () => pending.future;
    final disposedRefresh = key.currentState!.refresh();
    final beforeDispose = service.months.length;
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(snapshot());
    await disposedRefresh;
    await StorageService().saveBossHoursForDate('2026-10-01', 8.0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.months.length, beforeDispose);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字提示与按钮不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, textScaler: TextScaler.linear(2));
    expect(find.text('月底填报核对'), findsOneWidget);
    expect(find.text('查看建议'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
