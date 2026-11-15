import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/widgets/monthly_report_reminder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BlockedService extends MonthlyReportBalanceService {
  final gate = Completer<void>();
  int loads = 0;
  int active = 0;
  int maxActive = 0;
  @override
  DateTime get now => DateTime(2026, 10, 31, 20);
  @override
  Future<MonthlyReportSnapshot> load(DateTime month, {DateTime? now}) async {
    loads++;
    active++;
    if (active > maxActive) maxActive = active;
    await gate.future;
    active--;
    return MonthlyReportSnapshot(
      month: DateTime(2026, 10),
      asOf: this.now,
      lastWorkday: DateTime(2026, 10, 31),
      bossRevision: StorageService.bossHoursRevision,
      fingerprint: 'fixture-$loads',
      plan: MonthlyReportBalance.calculate(
        actualByDate: {'2026-10-01': 1006},
        reportedByDate: {},
      ),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('一次慢读取期间的20次通知合并为当前读取及一次最新重读', (tester) async {
    final service = _BlockedService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonthlyReportReminder(
            service: service,
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await StorageService().saveBossHoursForDate('2026-10-01', i.toDouble());
    }
    final loadsWhileBlocked = service.loads;
    final maxActive = service.maxActive;
    service.gate.complete();
    await tester.pumpAndSettle();
    debugPrint(
      'REMINDER_PERF blockedLoads=$loadsWhileBlocked maxConcurrent=$maxActive finalLoads=${service.loads}',
    );
    expect(loadsWhileBlocked, 1, reason: 'sequence淘汰结果不等于停止21次整月重算');
    expect(maxActive, 1);
    expect(service.loads, 2);
  });

  testWidgets('其他月份的工时更新不重算当前月份提醒', (tester) async {
    final service = _BlockedService()..gate.complete();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonthlyReportReminder(
            service: service,
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.loads, 1);
    for (var i = 0; i < 3; i++) {
      await StorageService().saveBossHoursForDate('2026-09-01', i.toDouble());
    }
    await tester.pumpAndSettle();
    debugPrint('REMINDER_OTHER_MONTH loads=${service.loads}');
    expect(service.loads, 1);
  });
}
