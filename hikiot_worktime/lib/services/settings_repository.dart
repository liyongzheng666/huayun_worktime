import '../core/constants/constants.dart';
import '../utils/work_time_calculator.dart';
import 'storage_service.dart';

class SettingsSnapshot {
  const SettingsSnapshot({
    required this.lunchStartTime,
    required this.lunchEndTime,
    required this.crossDayMinutes,
    required this.baseTarget,
    required this.minTarget,
    required this.hapticModeIndex,
    required this.reminderSettings,
    required this.extendedTargetRange,
    required this.debugToolsEnabled,
    this.userName,
    this.teamNo,
    this.teamName,
    this.token,
  });

  final String lunchStartTime;
  final String lunchEndTime;
  final int crossDayMinutes;
  final int baseTarget;

  /// 目标进度列表的起点百分比
  final int minTarget;
  final int hapticModeIndex;
  final ReminderSettings reminderSettings;
  final bool extendedTargetRange;
  final bool debugToolsEnabled;
  final String? userName;
  final String? teamNo;
  final String? teamName;
  final String? token;
}

class SettingsRepository {
  SettingsRepository({StorageService? storage})
    : _storage = storage ?? StorageService();

  final StorageService _storage;

  Future<SettingsSnapshot> load() async {
    final settings = await _storage.loadSettings();
    final reminderSettings = await _storage.loadReminderSettings();

    return SettingsSnapshot(
      lunchStartTime:
          settings['lunchStartTime'] as String? ??
          settings[StorageKeys.lunchStartTime] as String? ??
          AppConstants.defaultLunchStart,
      lunchEndTime:
          settings['lunchEndTime'] as String? ??
          settings[StorageKeys.lunchEndTime] as String? ??
          AppConstants.defaultLunchEnd,
      crossDayMinutes:
          settings[StorageKeys.crossDayMinutes] as int? ??
          AppConstants.defaultCrossDayMinutes,
      baseTarget: await _storage.loadBaseTarget(),
      minTarget: await _storage.loadMinTarget(),
      hapticModeIndex: await _storage.loadHapticModeIndex(),
      reminderSettings: reminderSettings,
      extendedTargetRange: await _storage.loadExtendedTargetRange(),
      debugToolsEnabled: await _storage.loadDebugToolsEnabled(),
      userName: await _storage.loadUserName(),
      teamNo: await _storage.loadTeamNo(),
      teamName: await _storage.loadTeamName(),
      token: await _storage.loadToken(),
    );
  }

  Future<void> saveLunchTimes({
    required String start,
    required String end,
  }) async {
    _validateLunchRange(start, end);
    final settings = await _storage.loadSettings();
    settings['lunchStartTime'] = start;
    settings['lunchEndTime'] = end;
    await _storage.saveSettings(settings);
    await WorkTimeCalculator.reload();
  }

  Future<void> saveTargetSettings({
    required bool extendedTargetRange,
    required int baseTarget,
  }) async {
    final normalizedTarget = !extendedTargetRange && baseTarget > 160
        ? 160
        : baseTarget;
    await _storage.saveExtendedTargetRange(extendedTargetRange);
    await _storage.saveBaseTarget(normalizedTarget);
  }

  Future<void> saveBaseTarget(int target) {
    return _storage.saveBaseTarget(target);
  }

  /// 保存最低目标。
  ///
  /// 最低目标必须不高于基础目标，否则目标列表会退化成只剩基础目标一项。
  /// 在这里夹紧而不是交给界面，是为了让任何调用方都拿不到非法组合。
  Future<void> saveMinTarget(int target) async {
    final baseTarget = await _storage.loadBaseTarget();
    await _storage.saveMinTarget(target > baseTarget ? baseTarget : target);
  }

  Future<void> saveExtendedTargetRange(bool enabled) {
    return _storage.saveExtendedTargetRange(enabled);
  }

  Future<void> saveDebugToolsEnabled(bool enabled) {
    return _storage.saveDebugToolsEnabled(enabled);
  }

  Future<String?> loadToken() {
    return _storage.loadToken();
  }

  Future<void> saveTokenForDebug(String token) {
    return _storage.saveToken(token);
  }

  Future<void> saveOnboardingCompleted(bool completed) {
    return _storage.saveOnboardingCompleted(completed);
  }

  Future<void> saveReminderTime({
    required bool isMorning,
    required bool enabled,
    required int hour,
    required int minute,
  }) {
    if (isMorning) {
      return _storage.saveMorningReminder(
        enabled: enabled,
        hour: hour,
        minute: minute,
      );
    }
    return _storage.saveEveningReminder(
      enabled: enabled,
      hour: hour,
      minute: minute,
    );
  }

  void _validateLunchRange(String start, String end) {
    final startMinutes = WorkTimeCalculator.parseTimeToMinutes(start);
    final endMinutes = WorkTimeCalculator.parseTimeToMinutes(end);
    if (startMinutes == null ||
        endMinutes == null ||
        endMinutes <= startMinutes) {
      throw ArgumentError('午休结束时间必须晚于开始时间');
    }
  }
}
