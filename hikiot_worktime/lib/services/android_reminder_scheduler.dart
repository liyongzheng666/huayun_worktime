import 'notification_service.dart';
import 'reminder_scheduler.dart';

/// Android 打卡提醒调度器
///
/// 走 AlarmManager 精确闹钟：系统会在指定时刻唤起后台 Dart isolate 执行回调，
/// 回调里可以真的联网拉今日考勤，再根据打卡结果现场拼出通知文案
/// （见 `punch_reminder_service.dart`）。这是 iOS 做不到的能力。
///
/// 代价是依赖厂商保活：国产 ROM 需要用户开启自启动、关闭省电优化，
/// 相关引导见 `phone_permission_guide.dart`。
class AndroidReminderScheduler implements ReminderScheduler {
  AndroidReminderScheduler([NotificationService? notificationService])
    : _notificationService = notificationService ?? NotificationService();

  final NotificationService _notificationService;

  @override
  Future<void> initialize() {
    return _notificationService.initialize();
  }

  @override
  Future<bool> requestNotificationPermission() {
    return _notificationService.requestNotificationPermission();
  }

  @override
  Future<bool> requestExactAlarmPermission() {
    return _notificationService.requestExactAlarmPermission();
  }

  @override
  Future<void> scheduleMorningAlarm(int hour, int minute) {
    return _notificationService.scheduleMorningAlarm(hour, minute);
  }

  @override
  Future<void> scheduleEveningAlarm(int hour, int minute) {
    return _notificationService.scheduleEveningAlarm(hour, minute);
  }

  @override
  Future<void> cancelMorningAlarm() {
    return _notificationService.cancelMorningAlarm();
  }

  @override
  Future<void> cancelEveningAlarm() {
    return _notificationService.cancelEveningAlarm();
  }
}
