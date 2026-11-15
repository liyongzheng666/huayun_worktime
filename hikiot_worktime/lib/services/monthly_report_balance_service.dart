import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/constants.dart';
import '../models/monthly_report_balance.dart';
import '../utils/calendar_mark_merge.dart';
import '../utils/date_helper.dart';
import '../utils/smart_day_type_helper.dart';
import '../utils/work_time_calculator.dart';
import '../utils/decimal_hours.dart';
import 'storage_service.dart';

/// 一次完整的月度核对结果；不可用与已核对无差额是不同状态。
class MonthlyReportSnapshot {
  const MonthlyReportSnapshot({
    required this.month,
    required this.asOf,
    required this.lastWorkday,
    required this.bossRevision,
    required this.fingerprint,
    this.plan,
    this.unavailableReason,
  });

  final DateTime month;
  final DateTime asOf;
  final DateTime lastWorkday;
  final MonthlyReportPlan? plan;
  final String? unavailableReason;
  final int bossRevision;

  /// 仅包含日期、工时和核对状态，不含账号凭据。
  final String fingerprint;

  bool get isReady => plan != null && unavailableReason == null;

  bool get showMonthEndReminder {
    final today = DateTime(asOf.year, asOf.month, asOf.day);
    if (today.isBefore(lastWorkday)) return false;
    return !isReady ||
        plan!.problem != null ||
        plan!.remainder > 0 ||
        plan!.suggestions.values.any((hours) => hours == 0);
  }
}

/// 汇总现有考勤与 BOSS 缓存，不在打开 App 时发起整月网络请求。
///
/// 只有实际工时完整、BOSS 各日确认仍有效的同一快照才能生成建议；
/// 缺失、失效及读取期间更新均保留为未知，不能伪装成尚未填报。
class MonthlyReportBalanceService {
  MonthlyReportBalanceService({
    StorageService? storage,
    DateTime Function()? clock,
  }) : _storage = storage ?? StorageService(),
       _clock = clock ?? DateTime.now;

  final StorageService _storage;
  final DateTime Function() _clock;

  DateTime get now => _clock();

  static String formatHundredths(int value) =>
      MonthlyReportBalance.formatHundredths(value);

  /// 先按十进制文本截到两位，再转整数，避免 1.15 * 100 的二进制误差。
  /// 实际单日工时不超过24小时；BOSS可能含重复日志，已填合计须保留用于纠偏。
  static int? parseHundredths(Object? value, {bool enforceDailyLimit = true}) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        (enforceDailyLimit && value > 24)) {
      return null;
    }
    return DecimalHours.tryHundredths(value);
  }

  Future<MonthlyReportSnapshot> load(DateTime month, {DateTime? now}) async {
    final normalizedMonth = DateTime(month.year, month.month);
    final moment = now ?? _clock();
    final today = DateHelper.getWorkDate(now: moment);
    final monthKey = DateHelper.formatMonth(normalizedMonth);
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final revision = StorageService.bossHoursRevision;
    var lastWorkday = monthEnd;
    String? team;

    MonthlyReportSnapshot unavailable(String reason) => MonthlyReportSnapshot(
      month: normalizedMonth,
      asOf: moment,
      lastWorkday: lastWorkday,
      bossRevision: revision,
      fingerprint: jsonEncode([team, monthKey, reason, revision]),
      unavailableReason: reason,
    );

    try {
      team = await _storage.loadTeamNo();
      final holidayPlan = await _storage.getHolidayPlan(month.year);
      final marks = team == null
          ? <String, Map<String, dynamic>>{}
          : await _storage.loadCalendarMarks(team);
      final cached = team == null
          ? null
          : await _storage.loadMonthlyData(team, monthKey);
      final merged = <String, Map<String, dynamic>>{};
      DateTime? foundLastWorkday;
      for (var day = 1; day <= monthEnd.day; day++) {
        final date = DateTime(month.year, month.month, day);
        final key = DateHelper.formatDate(date);
        final raw = cached?[key];
        final mark = marks[key];
        final value = raw == null
            ? null
            : mark == null
            ? Map<String, dynamic>.from(raw)
            : CalendarMarkMerge.applyMark(raw, mark);
        if (value != null) merged[key] = value;

        // 调休以计划和已确认的日类型为准；仅缺少安排时才回退周一至周五。
        final trustedType =
            value != null &&
            (value['isManual'] == true ||
                SmartDayTypeHelper.parseDataSourceStatus(
                      value[SmartDayTypeHelper.dataSourceStatusKey],
                    ) ==
                    DayDataSourceStatus.apiConfirmed);
        final manualType = mark == null || mark['isManual'] == false
            ? null
            : mark['type'];
        final workedType =
            trustedType &&
                _isWorkingType(value['type']) &&
                value['hours'] is num &&
                (value['hours'] as num) > 0
            ? value['type']
            : null;
        final type =
            (value != null && value['isManual'] == true
                ? value['type']
                : null) ??
            (value == null ? manualType : null) ??
            workedType ??
            holidayPlan[key] ??
            (trustedType ? value['type'] : null) ??
            value?['type'] ??
            (date.weekday <= 5
                ? AppConstants.typeWorkday
                : AppConstants.typeRestDay);
        if (_isWorkingType(type)) foundLastWorkday = date;
      }
      // 全月没有工作日时仍在月末核对，避免已填的异常工时永远没有入口。
      lastWorkday = foundLastWorkday ?? monthEnd;

      if (normalizedMonth.isAfter(today)) {
        return unavailable('未来月份尚无完整实际工时，暂不能生成建议');
      }
      if (team == null || team.isEmpty || cached == null) {
        return unavailable('请先同步本月考勤，实际工时尚未完整');
      }
      if (cached.keys.any((key) => !_isDateInMonth(key, monthKey))) {
        return unavailable('考勤缓存日期异常，请重新同步本月考勤');
      }

      // 原有读取器会滤掉无法解析的值；平衡不能把被滤掉的污染记录当成0。
      if (!await _reportedCacheIsValid(monthKey)) {
        return unavailable('华天已填工时缓存不完整或异常，请重新同步本月工时');
      }
      final boss = await _storage.loadBossHours(monthKey);
      if (boss.keys.any((key) => !_isDateInMonth(key, monthKey))) {
        return unavailable('华天已填报日期异常，请重新同步本月工时');
      }
      final objectIds = await _storage.loadWorkLogObjectIds();
      final end = today.isBefore(monthEnd) ? today : monthEnd;
      final actual = <String, int>{};
      final reported = <String, int>{};
      for (var day = 1; day <= monthEnd.day; day++) {
        final date = DateTime(month.year, month.month, day);
        final key = DateHelper.formatDate(date);
        final reportedValue = parseHundredths(
          boss[key] ?? 0,
          enforceDailyLimit: false,
        );
        if (reportedValue == null) {
          return unavailable('$key 的华天已填工时异常，请重新同步');
        }
        if (date.isAfter(end)) {
          if (reportedValue > 0 || objectIds.containsKey(key)) {
            return unavailable('$key 已有填报，但实际工时尚未完成，暂不能平衡');
          }
          continue;
        }

        final value = merged[key];
        if (value == null ||
            (value['isManual'] != true &&
                SmartDayTypeHelper.parseDataSourceStatus(
                      value[SmartDayTypeHelper.dataSourceStatusKey],
                    ) !=
                    DayDataSourceStatus.apiConfirmed)) {
          return unavailable('$key 的考勤尚未确认，请先同步本月考勤');
        }
        final type = value['type'];
        if (!_isKnownType(type)) {
          return unavailable('$key 的工作日类型无法确认，请核对考勤');
        }
        if (value['isManual'] != true &&
            _hasPunch(value['checkIn']) != _hasPunch(value['checkOut'])) {
          return unavailable(
            DateHelper.isSameDay(date, today) && _hasPunch(value['checkIn'])
                ? '$key 尚未取得下班打卡，实际工时未完成，请完成后刷新'
                : '$key 的打卡不完整，实际工时无法确认，请核对后刷新',
          );
        }
        final hours = parseHundredths(value['hours']);
        if (hours == null) {
          return unavailable('$key 的实际工时异常，请核对考勤');
        }
        actual[key] = _isWorkingType(type) ? hours : 0;
        if (!await _storage.hasFreshBossHoursForDate(key, now: moment)) {
          return unavailable('$key 的华天已填报状态待确认，请刷新本月华天工时');
        }
        // 0 小时的已知记录也属于已填日志，不能推荐再创建一条。
        if (reportedValue > 0 || objectIds.containsKey(key)) {
          reported[key] = reportedValue;
        }
      }
      if (team != await _storage.loadTeamNo()) {
        return unavailable('读取期间团队已切换，请刷新建议');
      }
      if (revision != StorageService.bossHoursRevision) {
        return unavailable('读取期间华天工时已更新，请刷新建议');
      }
      final plan = MonthlyReportBalance.calculate(
        actualByDate: actual,
        reportedByDate: reported,
      );
      return MonthlyReportSnapshot(
        month: normalizedMonth,
        asOf: moment,
        lastWorkday: lastWorkday,
        plan: plan,
        bossRevision: revision,
        fingerprint: jsonEncode([
          team,
          monthKey,
          DateHelper.formatDate(end),
          DateHelper.formatDate(lastWorkday),
          actual,
          reported,
          revision,
        ]),
      );
    } catch (_) {
      return unavailable('月度数据读取失败，请刷新考勤与华天工时后重试');
    }
  }

  /// 采用前重新读取，跨日、工时变化、确认过期都要求重新核对。
  Future<bool> isCurrent(MonthlyReportSnapshot snapshot) async {
    if (!snapshot.isReady) return false;
    final current = await load(snapshot.month);
    return current.isReady && current.fingerprint == snapshot.fingerprint;
  }

  static Future<bool> _reportedCacheIsValid(String monthKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.bossHoursKey(monthKey));
    if (raw == null) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return false;
    for (final entry in decoded.entries) {
      if (entry.key is! String || !_isDateInMonth(entry.key, monthKey)) {
        return false;
      }
      final value = entry.value;
      final parsed = value is String ? num.tryParse(value) : value;
      if (parseHundredths(parsed, enforceDailyLimit: false) == null) {
        return false;
      }
    }
    return true;
  }

  static bool _isDateInMonth(String key, String monthKey) {
    if (!key.startsWith('$monthKey-') || key.length != 10) return false;
    final parsed = DateTime.tryParse(key);
    return parsed != null && DateHelper.formatDate(parsed) == key;
  }

  static bool _hasPunch(Object? value) =>
      value is String && WorkTimeCalculator.parseTimeToMinutes(value) != null;

  static bool _isWorkingType(Object? type) =>
      type == AppConstants.typeWorkday ||
      type == AppConstants.typeOvertime ||
      type == AppConstants.typeBusinessTrip ||
      type == AppConstants.typeCustom;

  static bool _isKnownType(Object? type) =>
      _isWorkingType(type) ||
      type == AppConstants.typeLeave ||
      (type is String && SmartDayTypeHelper.isRestDayType(type));
}
