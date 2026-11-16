import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/constants.dart';
import '../utils/date_helper.dart';
import '../utils/decimal_hours.dart';

class _BossHoursChanges extends ChangeNotifier {
  String? lastMonth;

  void changed(String month) {
    lastMonth = month;
    notifyListeners();
  }
}

/// 一次读取的月度金额与确认证明，不在实例之间缓存结果。
class BossMonthSnapshot {
  const BossMonthSnapshot({
    required this.hours,
    required this.confirmedDates,
    required this.knownDates,
    required this.isValid,
    required this.consistent,
    required this.revision,
    this.ownedDates = const {},
  });

  final Map<String, double> hours;
  final Set<String> confirmedDates;
  final Set<String> knownDates;
  final bool isValid;
  final bool consistent;
  final int revision;
  final Set<String> ownedDates;
}

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
  /// 版本2使用整数分钟和十进制边界转换；旧派生缓存必须全月重新获取。
  static const monthlyHoursCalculationVersion = 2;
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

  // 历史键名保留以兼容iOS已有主题；两平台各自在本机使用同一套主题实现。
  static const String _appSkinKey = 'ios_app_skin';
  static const String _authRevisionKey = 'auth_identity_revision';
  static const String _bossCredentialIdentityKey = 'boss_credential_identity';

  /// 主题单独保存，避免工时设置整份写入时覆盖外观选择。
  Future<String?> loadAppSkinId() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.get(_appSkinKey);
    return value is String ? value : null;
  }

  Future<void> saveAppSkinId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (!await prefs.setString(_appSkinKey, id)) {
        throw StateError('主题保存失败');
      }
    } catch (_) {
      // 插件先改内存缓存再写磁盘；失败时重新读取，避免下次加载误用失败值。
      await prefs.reload();
      rethrow;
    }
  }

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
    if ((prefs.getString(StorageKeys.token)?.trim() ?? '') != normalizedToken) {
      await _revokeBossCredentialIdentity(prefs);
    }
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
      await _migrateStringPair(
        prefs,
        StorageKeys.userName,
        _legacyCurrentUserName,
        userName,
      );
    }
    return userName;
  }

  Future<void> saveTeamContext({
    required String teamNo,
    String? personNo,
    String? teamName,
    int? expectedAuthRevision,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final revision = expectedAuthRevision ?? await loadAuthRevision();
    if (revision != await loadAuthRevision()) {
      throw StateError('账号已变化，请重新加载身份');
    }
    await prefs.remove(_bossCredentialIdentityKey);
    await prefs.setString(StorageKeys.teamNo, teamNo);
    await prefs.setString(_legacyCurrentTeamNo, teamNo);
    if (personNo != null) {
      await prefs.setString(StorageKeys.personNo, personNo);
    }
    if (teamName != null && teamName.isNotEmpty) {
      await prefs.setString(StorageKeys.teamName, teamName);
      await prefs.setString(_legacyCurrentTeamName, teamName);
    }
    if (revision != await loadAuthRevision()) {
      throw StateError('账号已变化，请重新加载身份');
    }
    final token = await loadToken();
    if (token != null && teamNo.isNotEmpty && personNo?.isNotEmpty == true) {
      await prefs.setString(
        _bossCredentialIdentityKey,
        jsonEncode({
          'revision': revision,
          'scope': [teamNo, personNo],
        }),
      );
    }
  }

  Future<String?> loadTeamNo() async {
    final prefs = await SharedPreferences.getInstance();
    final teamNo =
        prefs.getString(StorageKeys.teamNo) ??
        prefs.getString(_legacyCurrentTeamNo);
    if (teamNo != null && teamNo.isNotEmpty) {
      await _migrateStringPair(
        prefs,
        StorageKeys.teamNo,
        _legacyCurrentTeamNo,
        teamNo,
      );
    }
    return teamNo;
  }

  Future<String?> loadTeamName() async {
    final prefs = await SharedPreferences.getInstance();
    final teamName =
        prefs.getString(StorageKeys.teamName) ??
        prefs.getString(_legacyCurrentTeamName);
    if (teamName != null && teamName.isNotEmpty) {
      await _migrateStringPair(
        prefs,
        StorageKeys.teamName,
        _legacyCurrentTeamName,
        teamName,
      );
    }
    return teamName;
  }

  /// 旧键迁移只补差异；热路径读取不再次跨平台持久化相同内容。
  Future<void> _migrateStringPair(
    SharedPreferences prefs,
    String key,
    String legacyKey,
    String value,
  ) async {
    if (prefs.getString(key) != value) await prefs.setString(key, value);
    if (prefs.getString(legacyKey) != value) {
      await prefs.setString(legacyKey, value);
    }
  }

  Future<String?> loadPersonNo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.personNo);
  }

  /// 仅返回当前主账号已确认的身份范围，供安全凭据隔离使用。
  Future<String?> loadBossCredentialScope() async {
    final prefs = await SharedPreferences.getInstance();
    if (await loadToken() == null) return null;
    final raw = prefs.getString(_bossCredentialIdentityKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['revision'] != await loadAuthRevision()) {
        return null;
      }
      final scope = value['scope'];
      if (scope is! List ||
          scope.length != 2 ||
          scope.any((item) => item is! String || item.isEmpty) ||
          scope[0] != await loadTeamNo() ||
          scope[1] != await loadPersonNo()) {
        return null;
      }
      if (value['revision'] != await loadAuthRevision()) return null;
      return jsonEncode(scope);
    } catch (_) {
      return null;
    }
  }

  /// 认证变更序号只用于拒绝迟到身份结果，不保存额外token或密码副本。
  Future<int> loadAuthRevision() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_authRevisionKey) ?? 0;
  }

  Future<void> _revokeBossCredentialIdentity(SharedPreferences prefs) async {
    await prefs.remove(_bossCredentialIdentityKey);
    await prefs.setInt(
      _authRevisionKey,
      (prefs.getInt(_authRevisionKey) ?? 0) + 1,
    );
  }

  Future<void> clearAuthInfo() async {
    final prefs = await SharedPreferences.getInstance();
    await _revokeBossCredentialIdentity(prefs);
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
    if (!await prefs.setString(key, jsonEncode(data))) {
      throw StateError('月度考勤缓存保存失败');
    }
  }

  /// 只补照片字段；读取到写回之间不 await，避免用旧日详情覆盖新工时和标记。
  Future<void> saveMonthlyDayPhotos(
    String teamNo,
    String date, {
    required String? checkInPhotoUrl,
    required String? checkOutPhotoUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = StorageKeys.monthlyDataKey(teamNo, date.substring(0, 7));
    final raw = prefs.getString(key);
    if (raw == null) return;
    dynamic month;
    try {
      month = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (month is! Map || month[date] is! Map) return;
    month[date]['checkInPhotoUrl'] = checkInPhotoUrl;
    month[date]['checkOutPhotoUrl'] = checkOutPhotoUrl;
    if (!await prefs.setString(key, jsonEncode(month))) {
      throw StateError('当天照片缓存保存失败');
    }
  }

  Future<int?> loadMonthlyHoursCalculationVersion(
    String teamNo,
    String monthKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.get(
      StorageKeys.monthlyHoursCalculationVersionKey(teamNo, monthKey),
    );
    return value is int ? value : null;
  }

  /// 仅在完整月份由当前算法重新计算并持久化后调用，单日或手工修改不升级。
  Future<void> saveMonthlyHoursCalculationVersion(
    String teamNo,
    String monthKey, {
    int version = monthlyHoursCalculationVersion,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setInt(
      StorageKeys.monthlyHoursCalculationVersionKey(teamNo, monthKey),
      version,
    )) {
      throw StateError('月度工时精度版本保存失败');
    }
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

  /// 工时或确认证明变化后通知；页面监听时只重新读取本地数据。
  static final _bossHoursChanges = _BossHoursChanges();
  static ChangeNotifier get bossHoursChanges => _bossHoursChanges;
  static String? get bossHoursChangedMonth => _bossHoursChanges.lastMonth;
  static int _bossHoursRevision = 0;
  static final Map<String, int> _bossDayRevisions = {};
  static Future<void>? _bossWriteTail;

  /// 网络请求开始前捕获，回写时防止旧请求覆盖期间更新的日期。
  static int get bossHoursRevision => _bossHoursRevision;

  static String _bossHoursOwnersKey(String month) => 'boss_hours_owners_$month';

  Map<String, String> _readBossHoursOwners(
    SharedPreferences prefs,
    String month,
  ) {
    try {
      final raw = prefs.getString(_bossHoursOwnersKey(month));
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// 完整月份的每一天均由同一身份确认过时才返回owner。
  Future<String?> loadBossHoursOwner(String monthKey) async {
    final snapshot = await loadBossMonthSnapshot(monthKey);
    if (!snapshot.isValid || !snapshot.consistent) return null;
    final prefs = await SharedPreferences.getInstance();
    final owners = _readBossHoursOwners(prefs, monthKey);
    final month = DateTime.tryParse('$monthKey-01');
    if (month == null) return null;
    String? result;
    for (
      var day = 1;
      day <= DateTime(month.year, month.month + 1, 0).day;
      day++
    ) {
      final owner = owners['$monthKey-${day.toString().padLeft(2, '0')}'];
      if (owner == null || (result != null && result != owner)) return null;
      result = owner;
    }
    return snapshot.revision == _bossHoursRevision && _bossWriteTail == null
        ? result
        : null;
  }

  Future<({int revision, String? scope, bool trusted})?> _bossWriteIdentity(
    String? expectedScope,
    int? expectedAuthRevision,
  ) async {
    final revision = await loadAuthRevision();
    final scope = await loadBossCredentialScope();
    final expected = expectedScope != null || expectedAuthRevision != null;
    if (expected &&
        (scope != expectedScope ||
            (expectedAuthRevision != null &&
                revision != expectedAuthRevision))) {
      return null;
    }
    return (
      revision: revision,
      scope: scope,
      trusted: expectedScope != null && expectedAuthRevision != null,
    );
  }

  Future<bool> _sameBossIdentity(
    ({int revision, String? scope, bool trusted}) identity,
  ) async =>
      identity.revision == await loadAuthRevision() &&
      identity.scope == await loadBossCredentialScope();

  Future<void> _writeBossHoursOwners(
    SharedPreferences prefs,
    String month,
    Iterable<String> dates,
    String? scope,
  ) async {
    final owners = _readBossHoursOwners(prefs, month);
    for (final date in dates) {
      if (scope == null) {
        owners.remove(date);
      } else {
        owners[date] = scope;
      }
    }
    final key = _bossHoursOwnersKey(month);
    if (owners.isEmpty) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    } else {
      final encoded = jsonEncode(owners);
      if (prefs.getString(key) != encoded &&
          !await prefs.setString(key, encoded)) {
        throw StateError('工时所属账号保存失败');
      }
    }
  }

  Future<void> _invalidateBossMonthProofs(
    SharedPreferences prefs,
    String month,
  ) async {
    final date = DateTime.parse('$month-01');
    for (
      var day = 1;
      day <= DateTime(date.year, date.month + 1, 0).day;
      day++
    ) {
      await prefs.remove(
        StorageKeys.bossHoursDateConfirmedAtKey(
          '$month-${day.toString().padLeft(2, '0')}',
        ),
      );
    }
    await prefs.remove(StorageKeys.bossHoursRefreshedAtKey(month));
    await prefs.remove(StorageKeys.bossHoursProofVersionKey(month));
    await prefs.remove(_bossHoursOwnersKey(month));
  }

  /// owner只属于发起请求时已验证且直到写入结束仍一致的账号。
  Future<void> _finishBossIdentityWrite(
    SharedPreferences prefs,
    String month,
    Iterable<String> dates,
    ({int revision, String? scope, bool trusted}) identity,
  ) async {
    if (!await _sameBossIdentity(identity)) {
      await _invalidateBossMonthProofs(prefs, month);
      return;
    }
    await _writeBossHoursOwners(
      prefs,
      month,
      dates,
      identity.trusted ? identity.scope : null,
    );
    if (!await _sameBossIdentity(identity)) {
      await _invalidateBossMonthProofs(prefs, month);
    }
  }

  Future<String?> _monthReportScope() async {
    final team = await loadTeamNo();
    final person = await loadPersonNo();
    if (team == null || team.isEmpty || person == null || person.isEmpty) {
      return null;
    }
    return jsonEncode([team, person]);
  }

  Future<String?> loadMonthReportReview(String month) async {
    final scope = await _monthReportScope();
    if (scope == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.get(StorageKeys.monthReportReviewKey(scope, month));
    return value is String ? value : null;
  }

  /// 只记录用户明确核对过的摘要；工时变化后的新摘要仍会再次提醒。
  Future<void> saveMonthReportReview(String month, String signature) async {
    final scope = await _monthReportScope();
    if (scope == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      StorageKeys.monthReportReviewKey(scope, month),
      signature,
    )) {
      throw StateError('月末核对状态保存失败');
    }
  }

  Future<void> _queueBossWrite(Future<void> Function() write) {
    final future = (_bossWriteTail ?? Future<void>.value()).then(
      (_) => write(),
    );
    // 后续写入不受前一次失败阻塞，原始 future 仍向调用者报告异常。
    final tail = future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    _bossWriteTail = tail;
    tail.then((_) {
      // 空闲后释放已完成 Future，避免下一次操作沿用旧调用 Zone。
      if (identical(_bossWriteTail, tail)) _bossWriteTail = null;
    });
    return future;
  }

  /// 服务端日志已变化，但尚未取得当日合计；仅阻止旧请求回写，不伪造工时。
  Future<void> markBossHoursDateChanged(String date) {
    if (DateTime.tryParse(date) == null) return Future<void>.value();
    return _queueBossWrite(() async {
      _bossDayRevisions[date] = ++_bossHoursRevision;
      final prefs = await SharedPreferences.getInstance();
      final wasConfirmed = await hasBossHoursForDate(date);
      await prefs.remove(StorageKeys.bossHoursDateConfirmedAtKey(date));
      await prefs.remove(
        StorageKeys.bossHoursProofVersionKey(date.substring(0, 7)),
      );
      await prefs.remove(
        StorageKeys.bossHoursRefreshedAtKey(date.substring(0, 7)),
      );
      await _writeBossHoursOwners(prefs, date.substring(0, 7), [date], null);
      if (wasConfirmed) _bossHoursChanges.changed(date.substring(0, 7));
    });
  }

  /// 更新某一天的 BOSS 已填工时，同时保留同月其他日期；0 也是已确认结果。
  Future<void> saveBossHoursForDate(
    String date,
    double hours, {
    int? expectedRevision,
    DateTime? refreshedAt,
    String? expectedScope,
    int? expectedAuthRevision,
  }) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null || !hours.isFinite || hours < 0) {
      return Future<void>.value();
    }
    final monthKey = date.substring(0, 7);
    return _queueBossWrite(() async {
      final identity = await _bossWriteIdentity(
        expectedScope,
        expectedAuthRevision,
      );
      if (identity == null) return;
      if (expectedRevision != null &&
          (_bossDayRevisions[date] ?? 0) > expectedRevision) {
        return;
      }
      final all = await loadBossHours(monthKey);
      all[date] = hours;
      await _writeBossHours(monthKey, all);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        StorageKeys.bossHoursDateConfirmedAtKey(date),
        (refreshedAt ?? DateTime.now()).toIso8601String(),
      );
      await _finishBossIdentityWrite(prefs, monthKey, [date], identity);
      _bossDayRevisions[date] = ++_bossHoursRevision;
      _bossHoursChanges.changed(monthKey);
    });
  }

  /// 保存完整月份结果，保留请求开始后已更新的日期。
  Future<void> saveBossHours(
    String monthKey,
    Map<String, double> hours, {
    DateTime? refreshedAt,
    int? expectedRevision,
    String? expectedScope,
    int? expectedAuthRevision,
  }) => _queueBossWrite(() async {
    final identity = await _bossWriteIdentity(
      expectedScope,
      expectedAuthRevision,
    );
    if (identity == null) return;
    final merged = Map<String, double>.from(hours);
    var completeMonth = true;
    final protectedDates = <String>{};
    final previous = await loadBossHours(monthKey);
    if (expectedRevision != null) {
      for (final entry in _bossDayRevisions.entries) {
        if (entry.key.startsWith('$monthKey-') &&
            entry.value > expectedRevision) {
          protectedDates.add(entry.key);
          if (!await hasBossHoursForDate(entry.key)) completeMonth = false;
          if (previous.containsKey(entry.key)) {
            merged[entry.key] = previous[entry.key]!;
          } else {
            merged.remove(entry.key);
            completeMonth = false;
          }
        }
      }
    }
    await _writeBossHours(monthKey, merged);
    final prefs = await SharedPreferences.getInstance();
    final confirmedAt = (refreshedAt ?? DateTime.now()).toIso8601String();
    final month = DateTime.parse('$monthKey-01');
    final days = DateTime(month.year, month.month + 1, 0).day;
    for (var day = 1; day <= days; day++) {
      final date = '$monthKey-${day.toString().padLeft(2, '0')}';
      if (!protectedDates.contains(date)) {
        await prefs.setString(
          StorageKeys.bossHoursDateConfirmedAtKey(date),
          confirmedAt,
        );
      }
    }
    if (completeMonth) {
      await prefs.setString(
        StorageKeys.bossHoursRefreshedAtKey(monthKey),
        confirmedAt,
      );
      await prefs.setInt(StorageKeys.bossHoursProofVersionKey(monthKey), 2);
    } else {
      // 有日期在请求期间变化且尚未取得合计，旧月份回包不能把这个孔洞当成 0。
      await prefs.remove(StorageKeys.bossHoursRefreshedAtKey(monthKey));
      await prefs.remove(StorageKeys.bossHoursProofVersionKey(monthKey));
    }
    await _finishBossIdentityWrite(prefs, monthKey, [
      for (var day = 1; day <= days; day++)
        if (!protectedDates.contains(
          '$monthKey-${day.toString().padLeft(2, '0')}',
        ))
          '$monthKey-${day.toString().padLeft(2, '0')}',
    ], identity);
    final revision = ++_bossHoursRevision;
    // 月份回包处理过的日期统一抬升版本，阻止更早的请求再次回写。
    for (var day = 1; day <= days; day++) {
      _bossDayRevisions['$monthKey-${day.toString().padLeft(2, '0')}'] =
          revision;
    }
    _bossHoursChanges.changed(monthKey);
  });

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

  /// 曾由严格校验后的结果确认过；不保证仍在当前状态的有效期内。
  Future<bool> hasBossHoursForDate(String date) async =>
      await _loadBossHoursDateConfirmedAt(date) != null;

  Future<DateTime?> _loadBossHoursDateConfirmedAt(String date) async {
    if (date.length != 10 || DateTime.tryParse(date) == null) return null;
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(StorageKeys.bossHoursKey(date.substring(0, 7)))) {
      return null;
    }
    return DateTime.tryParse(
      prefs.getString(StorageKeys.bossHoursDateConfirmedAtKey(date)) ?? '',
    );
  }

  /// 过期、旧版及未来时间的缓存均只能参考，不能判定已交或待补交。
  Future<bool> hasFreshBossHoursForDate(
    String date, {
    DateTime? now,
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    final confirmedAt = await _loadBossHoursDateConfirmedAt(date);
    if (confirmedAt == null) return false;
    final age = (now ?? DateTime.now()).difference(confirmedAt);
    return !age.isNegative && age < maxAge;
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
    return prefs.getInt(StorageKeys.bossHoursProofVersionKey(monthKey)) == 2 &&
        prefs.containsKey(StorageKeys.bossHoursKey(monthKey)) &&
        await loadBossHoursRefreshedAt(monthKey) != null;
  }

  /// 等待已排队的写入后，一次解析月度JSON并同步读取所有日期证明。
  /// 不复用上次结果；提交前核对、跨日与15分钟失效仍读取当前数据。
  Future<BossMonthSnapshot> loadBossMonthSnapshot(
    String monthKey, {
    DateTime? now,
    Duration maxAge = const Duration(minutes: 15),
    String? expectedScope,
  }) async {
    final pending = _bossWriteTail;
    if (pending != null) await pending;
    final revision = _bossHoursRevision;
    final prefs = await SharedPreferences.getInstance();
    final hours = _decodeValidBossHours(
      monthKey,
      prefs.getString(StorageKeys.bossHoursKey(monthKey)),
    );
    final knownDates = <String>{};
    final confirmedDates = <String>{};
    final ownedDates = <String>{};
    final owners = expectedScope == null
        ? const <String, String>{}
        : _readBossHoursOwners(prefs, monthKey);
    final month = DateTime.tryParse('$monthKey-01');
    if (hours != null && month != null) {
      final days = DateTime(month.year, month.month + 1, 0).day;
      final moment = now ?? DateTime.now();
      for (var day = 1; day <= days; day++) {
        final date = '$monthKey-${day.toString().padLeft(2, '0')}';
        final confirmedAt = DateTime.tryParse(
          prefs.getString(StorageKeys.bossHoursDateConfirmedAtKey(date)) ?? '',
        );
        if (confirmedAt == null) continue;
        knownDates.add(date);
        if (expectedScope != null && owners[date] == expectedScope) {
          ownedDates.add(date);
        }
        final age = moment.difference(confirmedAt);
        if (!age.isNegative && age < maxAge) confirmedDates.add(date);
      }
    }
    return BossMonthSnapshot(
      hours: Map.unmodifiable(hours ?? const <String, double>{}),
      confirmedDates: Set.unmodifiable(confirmedDates),
      knownDates: Set.unmodifiable(knownDates),
      isValid: hours != null,
      consistent: revision == _bossHoursRevision && _bossWriteTail == null,
      revision: revision,
      ownedDates: Set.unmodifiable(ownedDates),
    );
  }

  static Map<String, double>? _decodeValidBossHours(
    String monthKey,
    String? raw,
  ) {
    if (raw == null || !RegExp(r'^\d{4}-\d{2}$').hasMatch(monthKey)) {
      return null;
    }
    final month = DateTime.tryParse('$monthKey-01');
    if (month == null || DateHelper.formatMonth(month) != monthKey) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final result = <String, double>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        if (key is! String ||
            key.length != 10 ||
            !key.startsWith('$monthKey-')) {
          return null;
        }
        final date = DateTime.tryParse(key);
        if (date == null || DateHelper.formatDate(date) != key) return null;
        final value = entry.value;
        final parsed = value is String ? num.tryParse(value) : value;
        if (parsed is! num ||
            !parsed.isFinite ||
            parsed < 0 ||
            DecimalHours.tryHundredths(parsed) == null) {
          return null;
        }
        result[key] = parsed.toDouble();
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// 校验原始缓存，避免宽松读取器丢弃污染值后把它误当成已确认的0。
  /// 空表合法，但仍须由调用者逐日检查确认时间，才能用于完整月份判断。
  Future<bool> hasValidBossHoursCache(String monthKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _decodeValidBossHours(
            monthKey,
            prefs.getString(StorageKeys.bossHoursKey(monthKey)),
          ) !=
          null;
    } catch (_) {
      return false;
    }
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
    await _writeChangedPreference(
      prefs,
      StorageKeys.settings,
      jsonEncode(settings),
    );
    await _writeChangedPreference(
      prefs,
      StorageKeys.lunchStartTime,
      settings[StorageKeys.lunchStartTime] as String,
    );
    await _writeChangedPreference(
      prefs,
      StorageKeys.lunchEndTime,
      settings[StorageKeys.lunchEndTime] as String,
    );
    await _writeChangedPreference(
      prefs,
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

    await _writeChangedPreference(
      prefs,
      StorageKeys.morningReminderEnabled,
      settings.morningEnabled,
    );
    await _writeChangedPreference(
      prefs,
      StorageKeys.morningReminderTime,
      morningTime,
    );
    await _writeChangedPreference(
      prefs,
      StorageKeys.eveningReminderEnabled,
      settings.eveningEnabled,
    );
    await _writeChangedPreference(
      prefs,
      StorageKeys.eveningReminderTime,
      eveningTime,
    );

    await _writeChangedPreference(
      prefs,
      _legacyMorningEnabled,
      settings.morningEnabled,
    );
    await _writeChangedPreference(
      prefs,
      _legacyMorningHour,
      settings.morningHour,
    );
    await _writeChangedPreference(
      prefs,
      _legacyMorningMinute,
      settings.morningMinute,
    );
    await _writeChangedPreference(
      prefs,
      _legacyEveningEnabled,
      settings.eveningEnabled,
    );
    await _writeChangedPreference(
      prefs,
      _legacyEveningHour,
      settings.eveningHour,
    );
    await _writeChangedPreference(
      prefs,
      _legacyEveningMinute,
      settings.eveningMinute,
    );
  }

  /// 首次规范化仍持久化缺失项，随后读取只写变化字段。
  Future<void> _writeChangedPreference(
    SharedPreferences prefs,
    String key,
    Object value,
  ) async {
    if (prefs.get(key) == value) return;
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    }
  }

  String _formatReminderTime(int hour, int minute) {
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }
}
