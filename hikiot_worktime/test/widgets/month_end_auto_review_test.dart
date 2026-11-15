import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/widgets/monthly_report_reminder.dart';
import 'package:shared_preferences/shared_preferences.dart';

MonthlyReportSnapshot _value({
  int reported = 1020,
  int revision = 0,
  int day = 31,
  String? reason,
}) => MonthlyReportSnapshot(
  month: DateTime(2026, 10),
  asOf: DateTime(2026, 10, day, 20),
  lastWorkday: DateTime(2026, 10, 31),
  bossRevision: revision,
  fingerprint: 'proof-$revision',
  reviewScope: 'scope',
  unavailableReason: reason,
  plan: reason != null
      ? null
      : MonthlyReportBalance.calculate(
          actualByDate: {'2026-10-01': 1020},
          reportedByDate: {'2026-10-01': reported},
        ),
);

class _Service extends MonthlyReportBalanceService {
  MonthlyReportSnapshot value = _value();
  @override
  DateTime get now => value.asOf;
  @override
  Future<MonthlyReportSnapshot> load(DateTime month, {DateTime? now}) async =>
      value;
}

void main() {
  late _Service service;
  late GlobalKey<MonthlyReportReminderState> key;
  final storage = StorageService();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = _Service();
    key = GlobalKey();
    await storage.saveTeamContext(teamNo: 'test', personNo: 'person');
  });
  Future<void> open(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonthlyReportReminder(
            key: key,
            service: service,
            reviewStorage: storage,
            autoPromptEnabled: enabled,
            synchronizeMonth: (_) async {},
            child: const Text('主页面'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('调休末日启动即使差额为零也弹核对，明确核对后重启不重复', (tester) async {
    await open(tester);
    expect(find.text('本月填报差额核对'), findsOneWidget);
    expect(find.text('一致，差额 0.00 小时'), findsOneWidget);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    expect(
      await storage.loadMonthReportReview('2026-10'),
      service.value.reviewSignature,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    key = GlobalKey();
    await open(tester);
    expect(find.text('本月填报差额核对'), findsNothing);
  });

  testWidgets('只是缓存证明版本变化不重弹，工时摘要变化会再弹', (tester) async {
    await open(tester);
    await tester.tap(find.text('我已核对'));
    await tester.pumpAndSettle();
    service.value = _value(revision: 99);
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.text('本月填报差额核对'), findsNothing);
    service.value = _value(reported: 1000, revision: 100);
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.text('少填 0.20 小时'), findsOneWidget);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
  });

  testWidgets('月末之前不弹，启动准备完成后才允许自动弹窗', (tester) async {
    service.value = _value(day: 30);
    await open(tester);
    expect(find.text('本月填报差额核对'), findsNothing);
    service.value = _value();
    await open(tester, enabled: false);
    expect(find.text('本月填报差额核对'), findsNothing);
    await open(tester, enabled: true);
    expect(find.text('本月填报差额核对'), findsOneWidget);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
  });

  testWidgets('未知月额弹待确认，稍后不记已核对，返回前台再提醒', (tester) async {
    service.value = _value(reason: '请先同步考勤');
    await open(tester);
    expect(find.text('待确认'), findsNWidgets(3));
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '我已核对'),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
    expect(await storage.loadMonthReportReview('2026-10'), isNull);
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.text('本月填报差额核对'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('本月填报差额核对'), findsOneWidget);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
  });

  testWidgets('其它模态页面打开时不抢焦点，返回后刷新再弹', (tester) async {
    await open(tester, enabled: false);
    final context = tester.element(find.text('主页面'));
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('原确认'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await open(tester, enabled: true);
    expect(find.text('本月填报差额核对'), findsNothing);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(find.text('本月填报差额核对'), findsOneWidget);
    await tester.tap(find.text('稍后核对'));
    await tester.pumpAndSettle();
  });
}
