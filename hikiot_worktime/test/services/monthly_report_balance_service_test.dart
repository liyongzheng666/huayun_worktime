import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_attendance_repository.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ChangingStorage extends StorageService {
  bool changed = false;

  @override
  Future<bool> hasFreshBossHoursForDate(
    String date, {
    DateTime? now,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    final fresh = await super.hasFreshBossHoursForDate(
      date,
      now: now,
      maxAge: maxAge,
    );
    if (!changed) {
      changed = true;
      await saveBossHoursForDate('2026-09-01', 1, refreshedAt: now);
    }
    return fresh;
  }
}

void main() {
  const team = 'test-team';
  final month = DateTime(2026, 9);
  late DateTime now;
  late StorageService storage;
  late Map<String, Map<String, dynamic>> actual;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    now = DateTime(2026, 9, 3, 19);
    actual = {
      for (var day = 1; day <= 30; day++)
        DateHelper.formatDate(DateTime(2026, 9, day)): {
          'hours': 0.0,
          'type': DateTime(2026, 9, day).weekday <= 5
              ? AppConstants.typeWorkday
              : AppConstants.typeRestDay,
          'isManual': false,
          'dataSourceStatus': 'apiConfirmed',
          'checkIn': null,
          'checkOut': null,
        },
    };
  });

  void hours(int day, double value) {
    actual['2026-09-${day.toString().padLeft(2, '0')}']!.addAll({
      'hours': value,
      'type': AppConstants.typeWorkday,
      'checkIn': '08:00',
      'checkOut': '19:00',
    });
  }

  Future<void> seed({Map<String, double> reported = const {}}) async {
    await storage.saveTeamContext(teamNo: team);
    await storage.saveMonthlyData(team, '2026-09', actual);
    await storage.saveMonthlyHoursCalculationVersion(team, '2026-09');
    await storage.saveBossHours('2026-09', reported, refreshedAt: now);
  }

  MonthlyReportBalanceService service() =>
      MonthlyReportBalanceService(storage: storage, clock: () => now);

  test('旧精度考勤缓存不用于推荐，并明确要求全量同步', () async {
    hours(1, 10.19);
    await storage.saveTeamContext(teamNo: team);
    await storage.saveMonthlyData(team, '2026-09', actual);
    await storage.saveBossHours('2026-09', {}, refreshedAt: now);

    final result = await service().load(month);

    expect(result.isReady, isFalse);
    expect(result.plan, isNull);
    expect(result.unavailableReason, '精度已升级，请全量同步本月考勤后再核对');
    expect(
      (await storage.loadMonthlyData(team, '2026-09'))!['2026-09-01']!['hours'],
      10.19,
    );
  });

  test('完整重算和建议复读都不让旧自动标记10.19覆盖新API10.20，手工覆盖保留', () async {
    await storage.saveTeamContext(teamNo: team);
    hours(1, 10.19);
    await storage.saveMonthlyData(team, '2026-09', actual);
    await storage.saveSingleCalendarMark(team, '2026-09-01', {
      'type': AppConstants.typeOvertime,
      'isManual': false,
      'hours': 10.19,
    });
    await storage.saveSingleCalendarMark(team, '2026-09-02', {
      'type': AppConstants.typeWorkday,
      'isManual': true,
      'hours': 7.5,
    });
    await storage.saveBossHours('2026-09', {}, refreshedAt: now);
    final repository = MonthlyAttendanceRepository(
      storage: storage,
      loadMonthlyAttendance: (_, _) async => {
        'dailyRecords': [
          {
            'date': '2026-09-01',
            'hours': 10.2,
            'checkIn': '08:00',
            'checkOut': '19:12',
            'isRestDay': true,
          },
          {
            'date': '2026-09-02',
            'hours': 8.0,
            'checkIn': '09:00',
            'checkOut': '18:00',
          },
          {'date': '2026-09-03', 'hours': 0.0},
        ],
      },
      loadDailyAttendance: (_, _) async => null,
    );

    final recalculated = await repository.loadMonth(
      teamNo: team,
      personNo: 'test-person',
      selectedMonth: month,
    );
    final snapshot = await service().load(month);

    expect(snapshot.isReady, isTrue, reason: snapshot.unavailableReason);
    expect(snapshot.plan!.actualTotal, 1770);
    expect(recalculated.monthlyData['2026-09-01']!['hours'], 10.2);
    expect(recalculated.monthlyData['2026-09-01']!['apiHours'], 10.2);
    expect(recalculated.monthlyData['2026-09-02']!['hours'], 7.5);
    expect(recalculated.monthlyData['2026-09-02']!['isManual'], isTrue);
    expect(
      (await storage.loadCalendarMarks(team))['2026-09-01']!['hours'],
      10.19,
      reason: '无需删除旧标记，所有复读路径均须遵守最新API事实',
    );
  });

  test('真实缓存汇总三个待填日期，整数口径给出10.40且不改考勤', () async {
    hours(1, 10.42);
    hours(2, 10.37);
    hours(3, 10.41);
    await seed();
    final result = await service().load(month);
    expect(result.isReady, isTrue, reason: result.unavailableReason);
    expect(result.plan!.actualTotal, 3120);
    expect(result.plan!.suggestions, {
      '2026-09-01': 1040,
      '2026-09-02': 1040,
      '2026-09-03': 1040,
    });
    expect(result.showMonthEndReminder, isFalse);
    expect(
      (await storage.loadMonthlyData(team, '2026-09'))!['2026-09-02']!['hours'],
      10.37,
    );
    expect(await storage.loadBossHours('2026-09'), isEmpty);
  });

  test('已填日的多报和少报都计入未填额度', () async {
    hours(1, 10);
    hours(2, 10);
    await seed(reported: {'2026-09-01': 10.5});
    expect((await service().load(month)).plan!.suggestions, {
      '2026-09-02': 950,
    });
    await storage.saveBossHours('2026-09', {
      '2026-09-01': 9.5,
    }, refreshedAt: now);
    expect((await service().load(month)).plan!.suggestions, {
      '2026-09-02': 1050,
    });
  });

  test('实际为休息零工时的已填记录同样扣除；已知零小时记录不当作未填', () async {
    hours(2, 10);
    hours(3, 10);
    actual['2026-09-01']!['type'] = AppConstants.typeRestDay;
    await seed(reported: {'2026-09-01': 1});
    await storage.saveWorkLogObjectId('2026-09-03', 'WORKLOG_zero');
    final result = await service().load(month);
    expect(result.plan!.actualTotal, 2000);
    expect(result.plan!.reportedTotal, 100);
    expect(result.plan!.pendingActual.keys, ['2026-09-02']);
    expect(result.plan!.suggestions, {'2026-09-02': 1900});
  });

  test('考勤未知、缺日期和无有效团队均不给建议', () async {
    expect((await service().load(month)).isReady, isFalse);
    await seed();
    actual['2026-09-01']!['dataSourceStatus'] = 'unknown';
    await storage.saveMonthlyData(team, '2026-09', actual);
    expect((await service().load(month)).unavailableReason, contains('考勤尚未确认'));
    actual.remove('2026-09-01');
    await storage.saveMonthlyData(team, '2026-09', actual);
    expect((await service().load(month)).plan, isNull);
  });

  test('单日证明缺失、过期和来自未来均不能把空表当尚未提交', () async {
    hours(1, 10);
    await storage.saveTeamContext(teamNo: team);
    await storage.saveMonthlyData(team, '2026-09', actual);
    await storage.saveMonthlyHoursCalculationVersion(team, '2026-09');
    await storage.saveBossHoursForDate('2026-09-01', 0, refreshedAt: now);
    expect((await service().load(month)).unavailableReason, contains('状态待确认'));
    await storage.saveBossHours(
      '2026-09',
      {},
      refreshedAt: now.subtract(const Duration(minutes: 16)),
    );
    expect((await service().load(month)).isReady, isFalse);
    await storage.saveBossHours(
      '2026-09',
      {},
      refreshedAt: now.add(const Duration(seconds: 1)),
    );
    expect((await service().load(month)).isReady, isFalse);
  });

  test('污染的已填工时不能经过旧读取器过滤后伪装成0', () async {
    hours(1, 10);
    await seed();
    final prefs = await SharedPreferences.getInstance();
    for (final invalid in ['bad', -1, 'NaN', 'Infinity', null]) {
      await prefs.setString(
        StorageKeys.bossHoursKey('2026-09'),
        jsonEncode({'2026-09-01': invalid}),
      );
      final result = await service().load(month);
      expect(result.isReady, isFalse, reason: '$invalid');
      expect(result.unavailableReason, contains('异常'));
    }
  });

  test('读取中缓存发生更新时拒绝旧金额配新证明', () async {
    hours(1, 10);
    await seed();
    final result = await MonthlyReportBalanceService(
      storage: _ChangingStorage(),
      clock: () => now,
    ).load(month);
    expect(result.isReady, isFalse);
    expect(result.unavailableReason, contains('读取期间'));
  });

  test('重复日志导致已填合计超过24小时仍参与多报纠偏', () async {
    hours(1, 10);
    await seed(reported: {'2026-09-01': 25});
    final result = await service().load(month);
    expect(result.isReady, isTrue, reason: result.unavailableReason);
    expect(result.plan!.actualTotal, 1000);
    expect(result.plan!.reportedTotal, 2500);
    expect(result.plan!.remainingTotal, -1500);
    expect(result.plan!.problem, MonthlyReportProblem.overReported);
    expect(result.plan!.suggestions, isEmpty);
    expect(
      MonthlyReportBalanceService.formatHundredths(result.plan!.remainingTotal),
      '-15.00',
    );
  });

  test('今日仅上班卡未下班时明确拒绝，手动已完成工时可以参与', () async {
    hours(3, 10);
    actual['2026-09-03']!['checkOut'] = null;
    await seed();
    final incomplete = await service().load(month);
    expect(incomplete.isReady, isFalse);
    expect(incomplete.unavailableReason, contains('尚未取得下班打卡'));
    await storage.saveSingleCalendarMark(team, '2026-09-03', {
      'type': AppConstants.typeBusinessTrip,
      'isManual': true,
      'isCustomHours': false,
    });
    final completed = await service().load(month);
    expect(completed.plan!.actualTotal, 800);
  });

  test('未来日期不参与建议，已有未来填报须先核对', () async {
    hours(1, 10);
    hours(4, 12);
    await seed();
    final result = await service().load(month);
    expect(result.plan!.actualTotal, 1000);
    expect(result.plan!.suggestions.keys, ['2026-09-01']);
    await storage.saveBossHours('2026-09', {'2026-09-04': 1}, refreshedAt: now);
    expect(
      (await service().load(month)).unavailableReason,
      contains('实际工时尚未完成'),
    );
    expect((await service().load(DateTime(2026, 10))).isReady, isFalse);
  });

  test('过去日期单边缺卡不能把暂算0或部分工时纳入月额', () async {
    hours(1, 10);
    actual['2026-09-01']!['checkOut'] = null;
    await seed();
    expect((await service().load(month)).unavailableReason, contains('打卡不完整'));
    actual['2026-09-01']!.addAll({
      'hours': 0.0,
      'checkIn': null,
      'checkOut': '19:00',
    });
    await storage.saveMonthlyData(team, '2026-09', actual);
    expect((await service().load(month)).isReady, isFalse);
    actual['2026-09-01']!.addAll({
      'type': AppConstants.typeLeave,
      'checkOut': null,
    });
    await storage.saveMonthlyData(team, '2026-09', actual);
    expect((await service().load(month)).isReady, isTrue);
  });

  test('更新的调休计划覆盖旧缓存的周末类型', () async {
    hours(1, 10.42);
    await seed();
    await storage.saveHolidayPlan(2026, {
      '2026-09-26': AppConstants.typeWorkday,
      for (var day = 27; day <= 30; day++)
        '2026-09-$day': AppConstants.typeRestDay,
    });
    expect((await service().load(month)).lastWorkday, DateTime(2026, 9, 26));
  });

  test('调休周末作为最后工作日，到当天打开才提醒尾差', () async {
    now = DateTime(2026, 9, 26, 19);
    hours(1, 10.42);
    for (var day = 27; day <= 30; day++) {
      actual['2026-09-$day']!['dataSourceStatus'] = 'unknown';
    }
    await seed();
    await storage.saveHolidayPlan(2026, {
      for (var day = 26; day <= 30; day++)
        '2026-09-$day': day == 26
            ? AppConstants.typeWorkday
            : AppConstants.typeRestDay,
    });
    actual['2026-09-26']!['dataSourceStatus'] = 'unknown';
    await storage.saveMonthlyData(team, '2026-09', actual);
    await storage.saveSingleCalendarMark(team, '2026-09-26', {
      'type': AppConstants.typeWorkday,
      'isManual': true,
      'hours': 0.0,
    });
    final result = await service().load(month);
    expect(result.lastWorkday, DateTime(2026, 9, 26));
    expect(result.plan!.remainder, 2);
    expect(result.showMonthEndReminder, isTrue);
    now = DateTime(2026, 9, 25, 19);
    await storage.saveBossHours('2026-09', {}, refreshedAt: now);
    expect((await service().load(month)).showMonthEndReminder, isFalse);
  });

  test('手动请假不计工时，出差和自定义保留；自动旧请假不抹实际工作', () async {
    hours(1, 10);
    hours(2, 10);
    hours(3, 10);
    await seed();
    await storage.saveCalendarMarks(team, {
      '2026-09-01': {'type': AppConstants.typeLeave, 'isManual': true},
      '2026-09-02': {'type': AppConstants.typeBusinessTrip, 'isManual': true},
      '2026-09-03': {
        'type': AppConstants.typeCustom,
        'isManual': true,
        'customCheckIn': '09:00',
        'customCheckOut': '18:00',
      },
    });
    final marked = await service().load(month);
    expect(marked.plan!.actualTotal, 1600);
    await storage.saveCalendarMarks(team, {
      '2026-09-01': {'type': AppConstants.typeLeave, 'isManual': false},
    });
    expect((await service().load(month)).plan!.actualTotal, 3000);
  });

  test('采用前重读验证工时、跨日、团队及15分钟证明变化', () async {
    hours(1, 10.42);
    await seed();
    final reader = service();
    final snapshot = await reader.load(month);
    expect(await reader.isCurrent(snapshot), isTrue);
    now = now.add(const Duration(minutes: 16));
    expect(await reader.isCurrent(snapshot), isFalse);
    now = now.subtract(const Duration(minutes: 16));
    await storage.saveSingleCalendarMark(team, '2026-09-01', {
      'type': AppConstants.typeWorkday,
      'isManual': true,
      'hours': 9.0,
    });
    expect(await reader.isCurrent(snapshot), isFalse);
    final current = await reader.load(month);
    now = DateTime(2026, 9, 4, 19);
    expect(await reader.isCurrent(current), isFalse);
  });

  test('已到月末但数据未知也提醒同步，完整无差额才不提醒', () async {
    now = DateTime(2026, 9, 30, 19);
    final unknown = await service().load(month);
    expect(unknown.showMonthEndReminder, isTrue);
    expect(unknown.unavailableReason, isNotNull);
    await seed();
    expect((await service().load(month)).showMonthEndReminder, isFalse);
    hours(1, 10);
    await seed(reported: {'2026-09-01': 10.5});
    final over = await service().load(month);
    expect(over.plan!.problem, MonthlyReportProblem.overReported);
    expect(over.showMonthEndReminder, isTrue);
  });

  test('十进制解析保留精确两位、截断多余位并拒绝非法工时', () {
    expect(MonthlyReportBalanceService.parseHundredths(1.15), 115);
    expect(MonthlyReportBalanceService.parseHundredths(10.42), 1042);
    expect(MonthlyReportBalanceService.parseHundredths(10.429), 1042);
    expect(MonthlyReportBalanceService.parseHundredths(1e-7), 0);
    expect(MonthlyReportBalanceService.parseHundredths(-0.0), 0);
    expect(
      MonthlyReportBalanceService.parseHundredths(25, enforceDailyLimit: false),
      2500,
    );
    for (final value in [-1, double.nan, double.infinity, 24.01, '8.0', null]) {
      expect(MonthlyReportBalanceService.parseHundredths(value), isNull);
    }
    expect(MonthlyReportBalanceService.formatHundredths(-50), '-0.50');
  });

  test('待填工时被已填多报完全抵扣时月末提醒核对零额度', () async {
    now = DateTime(2026, 9, 30, 19);
    hours(1, 10);
    hours(2, 10);
    await seed(reported: {'2026-09-01': 20});
    final result = await service().load(month);
    expect(result.plan!.problem, isNull);
    expect(result.plan!.suggestions, {'2026-09-02': 0});
    expect(result.plan!.remainder, 0);
    expect(result.showMonthEndReminder, isTrue);
  });
}
