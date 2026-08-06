/// 提醒调度器接口，隔离权限请求与各平台的定时调度细节。
///
/// Android 实现见 `android_reminder_scheduler.dart`（AlarmManager 精确闹钟，
/// 触发时可联网拿实时打卡状态）；iOS 实现见 `ios_reminder_scheduler.dart`
/// （系统本地通知，文案在调度时冻结）。上层 `ReminderCoordinator` 只依赖本接口。
abstract class ReminderScheduler {
  Future<void> initialize();

  Future<bool> requestNotificationPermission();

  Future<bool> requestExactAlarmPermission();

  Future<void> scheduleMorningAlarm(int hour, int minute);

  Future<void> scheduleEveningAlarm(int hour, int minute);

  Future<void> cancelMorningAlarm();

  Future<void> cancelEveningAlarm();
}
