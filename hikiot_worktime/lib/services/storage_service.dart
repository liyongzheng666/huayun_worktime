import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/constants.dart';

class ReminderSettings {
  const ReminderSettings({
    required this.morningEnabled,
    required this.morningHour,
    required this.morningMinute,
    required this.eveningEnabled,
    required this.eveningHour,
    required this.eveningMinute,
  });

  final bool morningEnabled;
  final int morningHour;
  final int morningMinute;
  final bool eveningEnabled;
  final int eveningHour;
  final int eveningMinute;

  ReminderSettings copyWith({
    bool? morningEnabled,
    int? morningHour,
    int? morningMinute,
    bool? eveningEnabled,
    int? eveningHour,
    int? eveningMinute,
  }) {
    return ReminderSettings(
      morningEnabled: morningEnabled ?? this.morningEnabled,
      morningHour: morningHour ?? this.morningHour,
      morningMinute: morningMinute ?? this.morningMinute,
      eveningEnabled: eveningEnabled ?? this.eveningEnabled,
      eveningHour: eveningHour ?? this.eveningHour,
      eveningMinute: eveningMinute ?? this.eveningMinute,
    );
  }
}

/// Local storage facade for SharedPreferences.
class StorageService {
  static const String _legacyDisclaimerAccepted = 'disclaimer_shown';
  static const String _legacyCurrentTeamNo = 'current_team_no';
  static const String _legacyCurrentTeamName = 'current_team_name';
  static const String _legacyCurrentUserName = 'current_user_name';
  static const String _legacyMorningEnabled = 'morning_alarm_enabled';
  static const String _legacyMorningHour = 'morning_alarm_hour';
  static const String _legacyMorningMinute = 'morning_alarm_minute';
  static const String _legacyEveningEnabled = 'evening_alarm_enabled';
  static const String _legacyEveningHour = 'evening_alarm_hour';
  static const String _legacyEveningMinute = 'evening_alarm_minute';

  Future<void> saveBaseTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.baseTarget, target);
  }

  Future<int> loadBaseTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.baseTarget) ??
        AppConstants.defaultBaseTarget;
  }

  Future<void> saveMinTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.minTarget, target);
  }

  Future<int> loadMinTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.minTarget) ?? AppConstants.defaultMinTarget;
  }

  Future<void> saveExtendedTargetRange(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.extendedTargetRange, enabled);
  }

  Future<bool> loadExtendedTargetRange() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(StorageKeys.extendedTargetRange) ?? false;
  }

  Future<void> saveDebugToolsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.debugToolsEnabled, enabled);
  }

  Future<bool> loadDebugToolsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(StorageKeys.debugToolsEnabled) ?? false;
  }

  Future<void> saveHapticModeIndex(int modeIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.hapticMode, modeIndex);
  }

  Future<int> loadHapticModeIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.hapticMode) ?? 0;
  }

  Future<void> savePinnedTarget(int? target) async {
    final prefs = await SharedPreferences.getInstance();
    if (target == null) {
      await prefs.remove(StorageKeys.pinnedTarget);
    } else {
      await prefs.setInt(StorageKeys.pinnedTarget, target);
    }
  }

  Future<int?> loadPinnedTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.pinnedTarget);
  }

  Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) {
      await prefs.remove(StorageKeys.token);
      return;
    }
    await prefs.setString(StorageKeys.token, normalizedToken);
  }

  Future<String?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(StorageKeys.token);
    final normalizedToken = token?.trim();
    if (normalizedToken == null || normalizedToken.isEmpty) {
      if (token != null) {
        await prefs.remove(StorageKeys.token);
      }
      return null;
    }
    if (normalizedToken != token) {
      await prefs.setString(StorageKeys.token, normalizedToken);
    }
    return normalizedToken;
  }

  Future<void> saveUserName(String userName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.userName, userName);
    await prefs.setString(_legacyCurrentUserName, userName);
  }

  Future<String?> loadUserName() async {
    final prefs = await SharedPreferences.getInstance();
    final userName =
        prefs.getString(StorageKeys.userName) ??
        prefs.getString(_legacyCurrentUserName);
    if (userName != null && userName.isNotEmpty) {
      await prefs.setString(StorageKeys.userName, userName);
      await prefs.setString(_legacyCurrentUserName, userName);
    }
    return userName;
  }

  Future<void> saveTeamContext({
    required String teamNo,
    String? personNo,
    String? teamName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.teamNo, teamNo);
    await prefs.setString(_legacyCurrentTeamNo, teamNo);
    if (personNo != null) {
      await prefs.setString(StorageKeys.personNo, personNo);
    }
    if (teamName != null && teamName.isNotEmpty) {
      await prefs.setString(StorageKeys.teamName, teamName);
      await prefs.setString(_legacyCurrentTeamName, teamName);
    }
  }

  Future<String?> loadTeamNo() async {
    final prefs = await SharedPreferences.getInstance();
    final teamNo =
        prefs.getString(StorageKeys.teamNo) ??
        prefs.getString(_legacyCurrentTeamNo);
    if (teamNo != null && teamNo.isNotEmpty) {
      await prefs.setString(StorageKeys.teamNo, teamNo);
      await prefs.setString(_legacyCurrentTeamNo, teamNo);
    }
    return teamNo;
  }

  Future<String?> loadTeamName() async {
    final prefs = await SharedPreferences.getInstance();
    final teamName =
        prefs.getString(StorageKeys.teamName) ??
        prefs.getString(_legacyCurrentTeamName);
    if (teamName != null && teamName.isNotEmpty) {
      await prefs.setString(StorageKeys.teamName, teamName);
      await prefs.setString(_legacyCurrentTeamName, teamName);
    }
    return teamName;
  }

  Future<String?> loadPersonNo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.personNo);
  }

  Future<void> clearAuthInfo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.token);
    await prefs.remove(StorageKeys.userName);
    await prefs.remove(_legacyCurrentUserName);
  }

  Future<void> saveOnboardingCompleted(bool completed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.onboardingCompleted, completed);
  }

  Future<bool> loadOnboardingCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(StorageKeys.onboardingCompleted) ?? false;
  }

  Future<void> saveDisclaimerAccepted(bool accepted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.disclaimerAccepted, accepted);
    await prefs.setBool(_legacyDisclaimerAccepted, accepted);
  }

  Future<bool> loadDisclaimerAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted =
        prefs.getBool(StorageKeys.disclaimerAccepted) ??
        prefs.getBool(_legacyDisclaimerAccepted) ??
        false;
    await prefs.setBool(StorageKeys.disclaimerAccepted, accepted);
    await prefs.setBool(_legacyDisclaimerAccepted, accepted);
    return accepted;
  }

  Future<void> saveSelectedTeam(String teamNo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.selectedTeam, teamNo);
  }

  Future<String?> loadSelectedTeam() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.selectedTeam);
  }

  Future<void> saveCalendarMarks(
    String teamNo,
    Map<String, Map<String, dynamic>> marks,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = StorageKeys.calendarMarksKey(teamNo);
    await prefs.setString(key, jsonEncode(marks));
  }

  Future<void> saveSingleCalendarMark(
    String teamNo,
    String dateStr,
    Map<String, dynamic> markData,
  ) async {
    final marks = await loadCalendarMarks(teamNo);
    marks[dateStr] = markData;
    await saveCalendarMarks(teamNo, marks);
  }

  Future<Map<String, Map<String, dynamic>>> loadCalendarMarks(
    String teamNo,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.calendarMarksKey(teamNo));
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) =>
            MapEntry(key as String, Map<String, dynamic>.from(value as Map)),
      );
    } catch (e) {
      return {};
    }
  }

  Future<void> saveMonthlyData(
    String teamNo,
    String monthKey,
    Map<String, Map<String, dynamic>> data,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = StorageKeys.monthlyDataKey(teamNo, monthKey);
    await prefs.setString(key, jsonEncode(data));
  }

  Future<Map<String, Map<String, dynamic>>?> loadMonthlyData(
    String teamNo,
    String monthKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(
      StorageKeys.monthlyDataKey(teamNo, monthKey),
    );
    if (jsonStr == null) return null;

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return null;
      return decoded.map(
        (key, value) =>
            MapEntry(key as String, Map<String, dynamic>.from(value as Map)),
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> saveHolidayPlan(int year, Map<String, String> plan) async {
    final prefs = await SharedPreferences.getInstance();
    final allPlans = await loadAllHolidayPlans();
    allPlans[year.toString()] = plan;
    await prefs.setString(StorageKeys.holidayPlan, jsonEncode(allPlans));
  }

  Future<Map<String, Map<String, String>>> loadAllHolidayPlans() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.holidayPlan);
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      return decoded.map(
        (year, plan) =>
            MapEntry(year as String, Map<String, String>.from(plan as Map)),
      );
    } catch (e) {
      return {};
    }
  }

  Future<Map<String, String>> getHolidayPlan(int year) async {
    final allPlans = await loadAllHolidayPlans();
    return allPlans[year.toString()] ?? {};
  }

  Map<String, String> generateDefaultPlan(int year, int month) {
    final plan = <String, String>{};
    final daysInMonth = DateTime(year, month + 1, 0).day;

    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(year, month, day);
      final type = date.weekday >= 1 && date.weekday <= 5
          ? AppConstants.typeWorkday
          : AppConstants.typeRestDay;
      final dateStr =
          '${year.toString().padLeft(4, '0')}-'
          '${month.toString().padLeft(2, '0')}-'
          '${day.toString().padLeft(2, '0')}';
      plan[dateStr] = type;
    }

    return plan;
  }

  Future<String> getDayType(String dateStr) async {
    final date = DateTime.parse(dateStr);
    final plan = await getHolidayPlan(date.year);
    if (plan.containsKey(dateStr)) {
      return plan[dateStr]!;
    }

    return date.weekday >= 1 && date.weekday <= 5
        ? AppConstants.typeWorkday
        : AppConstants.typeRestDay;
  }

  // ============ 工作日志 ============

  /// 保存导入的工作日志（按日期归档）及其来源元信息。
  Future<void> saveWorkLogEntries(
    Map<String, Map<String, dynamic>> entries, {
    String? sourceName,
    DateTime? importedAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.workLogEntries, jsonEncode(entries));
    if (sourceName != null && sourceName.isNotEmpty) {
      await prefs.setString(StorageKeys.workLogSourceName, sourceName);
    }
    await prefs.setString(
      StorageKeys.workLogImportedAt,
      (importedAt ?? DateTime.now()).toIso8601String(),
    );
  }

  Future<Map<String, Map<String, dynamic>>> loadWorkLogEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.workLogEntries);
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) =>
            MapEntry(key as String, Map<String, dynamic>.from(value as Map)),
      );
    } catch (e) {
      return {};
    }
  }

  /// 返回 (来源文件名, 导入时间)，未导入过时均为 null。
  Future<(String?, DateTime?)> loadWorkLogMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final sourceName = prefs.getString(StorageKeys.workLogSourceName);
    final importedAtStr = prefs.getString(StorageKeys.workLogImportedAt);
    return (sourceName, DateTime.tryParse(importedAtStr ?? ''));
  }

  /// 保存 BOSS 提交所需的固定业务标识。
  ///
  /// 只接受项目 ID/编码与审核人 ID 这类业务标识；调用方不得把
  /// Password、LoginID 等会话凭据传进来（BOSS 把凭据放在每个请求体里，
  /// 一旦落盘等同于本地明文保存登录凭据）。
  Future<void> saveBossConstants(Map<String, String> constants) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.workLogBossConstants,
      jsonEncode(constants),
    );
  }

  /// 清除已保存的 BOSS 提交配置。
  ///
  /// 需要独立方法而不是保存一份空值：清除后应回到「从未配置」状态，
  /// 好让后台自动学习重新介入；留一份空 Map 在那里语义上是含糊的。
  ///
  /// **按项目名记住的绑定一并清掉**：用户点「清除配置」的意思是「全部重来」，
  /// 留着一份看不见的绑定，会让他清完之后发现项目还是老样子，且无从下手。
  Future<void> clearBossConstants() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.workLogBossConstants);
    await prefs.remove(StorageKeys.workLogProjectBindings);
  }

  /// 记住「CSV 里的 [csvProjectName] 用这份配置提交」。
  ///
  /// 与 [saveBossConstants] 一起写：后者是「最近一次用的配置」，供设置页显示和
  /// 后台学习判断；这里才是真正的记忆。只写后者的话，用户在两个项目间来回切
  /// 会互相覆盖，界面上承诺的「之后不再询问」就成了空话。
  Future<void> saveBossBinding(
    String csvProjectName,
    Map<String, String> constants,
  ) async {
    if (csvProjectName.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final all = await loadBossBindings();
    all[csvProjectName] = constants;
    await prefs.setString(StorageKeys.workLogProjectBindings, jsonEncode(all));
  }

  /// 取 [csvProjectName] 记住的配置，没有则返回 null。
  Future<Map<String, String>?> loadBossBinding(String csvProjectName) async {
    if (csvProjectName.isEmpty) return null;
    return (await loadBossBindings())[csvProjectName];
  }

  /// 全部按项目名记住的配置。解析不了时当作没有，不抛错。
  Future<Map<String, Map<String, String>>> loadBossBindings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.workLogProjectBindings);
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};

      final out = <String, Map<String, String>>{};
      decoded.forEach((key, value) {
        if (value is! Map) return;
        out['$key'] = value.map((k, v) => MapEntry('$k', '$v'));
      });
      return out;
    } catch (e) {
      return {};
    }
  }

  Future<Map<String, String>> loadBossConstants() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.workLogBossConstants);
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } catch (e) {
      return {};
    }
  }

  /// 记住 App 为某天创建成功的 BOSS 日志 ID，供刷新后进入编辑。
  Future<void> saveWorkLogObjectId(String date, String objectId) async {
    if (date.isEmpty || !objectId.startsWith('WORKLOG_')) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await loadWorkLogObjectIds();
    all[date] = objectId;
    await prefs.setString(StorageKeys.workLogObjectIds, jsonEncode(all));
  }

  Future<void> saveBossLoginUserName(String userName) async {
    final prefs = await SharedPreferences.getInstance();
    final value = userName.trim();
    if (value.isEmpty) {
      await prefs.remove(StorageKeys.bossLoginUserName);
    } else {
      await prefs.setString(StorageKeys.bossLoginUserName, value);
    }
  }

  Future<String> loadBossLoginUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.bossLoginUserName)?.trim() ?? '';
  }

  Future<String?> loadWorkLogObjectId(String date) async {
    if (date.isEmpty) return null;
    return (await loadWorkLogObjectIds())[date];
  }

  Future<Map<String, String>> loadWorkLogObjectIds() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.workLogObjectIds);
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      final result = <String, String>{};
      decoded.forEach((date, value) {
        final objectId = '$value';
        if (objectId.startsWith('WORKLOG_')) result['$date'] = objectId;
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> removeWorkLogObjectId(String date) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadWorkLogObjectIds();
    if (all.remove(date) == null) return;
    await prefs.setString(StorageKeys.workLogObjectIds, jsonEncode(all));
  }

  /// 更新某一天的 BOSS 已填工时，同时保留同月其他日期。
  Future<void> saveBossHoursForDate(String date, double hours) async {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return;
    final monthKey =
        '${parsed.year.toString().padLeft(4, '0')}-'
        '${parsed.month.toString().padLeft(2, '0')}';
    final all = await loadBossHours(monthKey);
    if (hours > 0) {
      all[date] = hours;
    } else {
      all.remove(date);
    }
    await _writeBossHours(monthKey, all);
  }

  /// 保存 BOSS 某月已填工时（日期 → 工时）。
  Future<void> saveBossHours(
    String monthKey,
    Map<String, double> hours, {
    DateTime? refreshedAt,
  }) async {
    await _writeBossHours(monthKey, hours);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.bossHoursRefreshedAtKey(monthKey),
      (refreshedAt ?? DateTime.now()).toIso8601String(),
    );
  }

  Future<void> _writeBossHours(
    String monthKey,
    Map<String, double> hours,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.bossHoursKey(monthKey),
      jsonEncode(hours),
    );
  }

  Future<DateTime?> loadBossHoursRefreshedAt(String monthKey) async {
    final prefs = await SharedPreferences.getInstance();
    return DateTime.tryParse(
      prefs.getString(StorageKeys.bossHoursRefreshedAtKey(monthKey)) ?? '',
    );
  }

  /// 该月是否同步过 BOSS 工时。
  ///
  /// 空表既可能是「同步过但一条都没填」，也可能是「从没同步过」。
  /// 两者在界面上必须分开：把「不知道」显示成「没填报」，
  /// 会让没同步过的月份整片误报成欠账。
  Future<bool> hasBossHoursSynced(String monthKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(StorageKeys.bossHoursKey(monthKey));
  }

  Future<Map<String, double>> loadBossHours(String monthKey) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(StorageKeys.bossHoursKey(monthKey));
    if (jsonStr == null) return {};

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return {};
      final result = <String, double>{};
      decoded.forEach((key, value) {
        final parsed = value is num
            ? value.toDouble()
            : double.tryParse('$value');
        if (parsed != null) result['$key'] = parsed;
      });
      return result;
    } catch (e) {
      return {};
    }
  }

  Future<void> clearWorkLogEntries() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.workLogEntries);
    await prefs.remove(StorageKeys.workLogSourceName);
    await prefs.remove(StorageKeys.workLogImportedAt);
  }

  Future<ReminderSettings> loadReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final morningTime = _readReminderTime(
      prefs.getString(StorageKeys.morningReminderTime),
      legacyHour: prefs.getInt(_legacyMorningHour),
      legacyMinute: prefs.getInt(_legacyMorningMinute),
      defaultHour: 8,
      defaultMinute: 55,
    );
    final eveningTime = _readReminderTime(
      prefs.getString(StorageKeys.eveningReminderTime),
      legacyHour: prefs.getInt(_legacyEveningHour),
      legacyMinute: prefs.getInt(_legacyEveningMinute),
      defaultHour: 21,
      defaultMinute: 0,
    );
    final settings = ReminderSettings(
      morningEnabled:
          prefs.getBool(StorageKeys.morningReminderEnabled) ??
          prefs.getBool(_legacyMorningEnabled) ??
          false,
      morningHour: morningTime.$1,
      morningMinute: morningTime.$2,
      eveningEnabled:
          prefs.getBool(StorageKeys.eveningReminderEnabled) ??
          prefs.getBool(_legacyEveningEnabled) ??
          false,
      eveningHour: eveningTime.$1,
      eveningMinute: eveningTime.$2,
    );
    await _persistReminderSettings(prefs, settings);
    return settings;
  }

  Future<void> saveMorningReminder({
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    final current = await loadReminderSettings();
    final next = current.copyWith(
      morningEnabled: enabled,
      morningHour: hour,
      morningMinute: minute,
    );
    final prefs = await SharedPreferences.getInstance();
    await _persistReminderSettings(prefs, next);
  }

  Future<void> saveEveningReminder({
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    final current = await loadReminderSettings();
    final next = current.copyWith(
      eveningEnabled: enabled,
      eveningHour: hour,
      eveningMinute: minute,
    );
    final prefs = await SharedPreferences.getInstance();
    await _persistReminderSettings(prefs, next);
  }

  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeSettings(settings);
    await _persistSettings(prefs, normalized);
  }

  Future<Map<String, dynamic>> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = <String, dynamic>{};
    final jsonStr = prefs.getString(StorageKeys.settings);

    try {
      if (jsonStr != null) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          settings.addAll(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (e) {
      settings.clear();
    }

    final storedLunchStart = prefs.getString(StorageKeys.lunchStartTime);
    final storedLunchEnd = prefs.getString(StorageKeys.lunchEndTime);
    final storedCrossDay = prefs.getInt(StorageKeys.crossDayMinutes);
    if (storedLunchStart != null) {
      settings[StorageKeys.lunchStartTime] = storedLunchStart;
    }
    if (storedLunchEnd != null) {
      settings[StorageKeys.lunchEndTime] = storedLunchEnd;
    }
    if (storedCrossDay != null) {
      settings[StorageKeys.crossDayMinutes] = storedCrossDay;
    }

    final normalized = _normalizeSettings(settings);
    await _persistSettings(prefs, normalized);
    return normalized;
  }

  Map<String, dynamic> _defaultSettings() {
    return {
      'targets': List<int>.from(AppConstants.standardTargets),
      StorageKeys.lunchStartTime: AppConstants.defaultLunchStart,
      StorageKeys.lunchEndTime: AppConstants.defaultLunchEnd,
      StorageKeys.crossDayMinutes: AppConstants.defaultCrossDayMinutes,
      'lunchStartTime': AppConstants.defaultLunchStart,
      'lunchEndTime': AppConstants.defaultLunchEnd,
      'lunch_break': {
        'start': AppConstants.defaultLunchStart,
        'end': AppConstants.defaultLunchEnd,
      },
      'day_change_hour': AppConstants.defaultCrossDayMinutes ~/ 60,
      'display_name': '',
    };
  }

  Map<String, dynamic> _normalizeSettings(Map<String, dynamic> rawSettings) {
    final normalized = <String, dynamic>{..._defaultSettings(), ...rawSettings};

    final lunchStart =
        _readString(rawSettings, 'lunchStartTime') ??
        _readString(rawSettings, StorageKeys.lunchStartTime) ??
        _readNestedString(rawSettings, 'lunch_break', 'start') ??
        AppConstants.defaultLunchStart;
    final lunchEnd =
        _readString(rawSettings, 'lunchEndTime') ??
        _readString(rawSettings, StorageKeys.lunchEndTime) ??
        _readNestedString(rawSettings, 'lunch_break', 'end') ??
        AppConstants.defaultLunchEnd;
    final legacyCrossDayHour = _readInt(rawSettings, 'day_change_hour');
    final crossDayMinutes =
        _readInt(rawSettings, StorageKeys.crossDayMinutes) ??
        _readInt(rawSettings, 'crossDayMinutes') ??
        (legacyCrossDayHour != null ? legacyCrossDayHour * 60 : null) ??
        AppConstants.defaultCrossDayMinutes;

    normalized[StorageKeys.lunchStartTime] = lunchStart;
    normalized[StorageKeys.lunchEndTime] = lunchEnd;
    normalized[StorageKeys.crossDayMinutes] = crossDayMinutes;
    normalized['lunchStartTime'] = lunchStart;
    normalized['lunchEndTime'] = lunchEnd;
    normalized['lunch_break'] = {'start': lunchStart, 'end': lunchEnd};
    normalized['day_change_hour'] = crossDayMinutes ~/ 60;

    return normalized;
  }

  Future<void> _persistSettings(
    SharedPreferences prefs,
    Map<String, dynamic> settings,
  ) async {
    await prefs.setString(StorageKeys.settings, jsonEncode(settings));
    await prefs.setString(
      StorageKeys.lunchStartTime,
      settings[StorageKeys.lunchStartTime] as String,
    );
    await prefs.setString(
      StorageKeys.lunchEndTime,
      settings[StorageKeys.lunchEndTime] as String,
    );
    await prefs.setInt(
      StorageKeys.crossDayMinutes,
      settings[StorageKeys.crossDayMinutes] as int,
    );
  }

  String? _readString(Map<String, dynamic> source, String key) {
    final value = source[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  String? _readNestedString(
    Map<String, dynamic> source,
    String parentKey,
    String childKey,
  ) {
    final parent = source[parentKey];
    if (parent is! Map) return null;
    final value = parent[childKey];
    return value is String && value.isNotEmpty ? value : null;
  }

  int? _readInt(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  (int, int) _readReminderTime(
    String? canonicalTime, {
    required int? legacyHour,
    required int? legacyMinute,
    required int defaultHour,
    required int defaultMinute,
  }) {
    final parsed = _parseReminderTime(canonicalTime);
    if (parsed != null) return parsed;

    final hour = legacyHour ?? defaultHour;
    final minute = legacyMinute ?? defaultMinute;
    if (_isValidReminderTime(hour, minute)) {
      return (hour, minute);
    }

    return (defaultHour, defaultMinute);
  }

  (int, int)? _parseReminderTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return _isValidReminderTime(hour, minute) ? (hour, minute) : null;
  }

  bool _isValidReminderTime(int hour, int minute) {
    return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
  }

  Future<void> _persistReminderSettings(
    SharedPreferences prefs,
    ReminderSettings settings,
  ) async {
    final morningTime = _formatReminderTime(
      settings.morningHour,
      settings.morningMinute,
    );
    final eveningTime = _formatReminderTime(
      settings.eveningHour,
      settings.eveningMinute,
    );

    await prefs.setBool(
      StorageKeys.morningReminderEnabled,
      settings.morningEnabled,
    );
    await prefs.setString(StorageKeys.morningReminderTime, morningTime);
    await prefs.setBool(
      StorageKeys.eveningReminderEnabled,
      settings.eveningEnabled,
    );
    await prefs.setString(StorageKeys.eveningReminderTime, eveningTime);

    await prefs.setBool(_legacyMorningEnabled, settings.morningEnabled);
    await prefs.setInt(_legacyMorningHour, settings.morningHour);
    await prefs.setInt(_legacyMorningMinute, settings.morningMinute);
    await prefs.setBool(_legacyEveningEnabled, settings.eveningEnabled);
    await prefs.setInt(_legacyEveningHour, settings.eveningHour);
    await prefs.setInt(_legacyEveningMinute, settings.eveningMinute);
  }

  String _formatReminderTime(int hour, int minute) {
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }
}
