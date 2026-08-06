import 'android_reminder_scheduler.dart';
import 'ios_reminder_scheduler.dart';
import 'platform_capabilities.dart';
import 'reminder_scheduler.dart';

// 对外继续从本文件暴露 ReminderScheduler，调用方和既有测试无需感知接口被拆分。
export 'reminder_scheduler.dart';

/// 提醒开关操作结果。
enum ReminderToggleResult {
  enabled,
  disabled,
  notificationPermissionDenied,
  exactAlarmPermissionDenied,
}

/// 按当前平台能力选择提醒调度器。
///
/// Android 走精确闹钟 + 后台联网实时文案；iOS 走系统本地通知 + 固定文案。
ReminderScheduler createDefaultReminderScheduler() {
  return PlatformCapabilities.supportsExactBackgroundAlarm
      ? AndroidReminderScheduler()
      : IosReminderScheduler();
}

/// 提醒设置协调器：统一处理权限闭环与实际调度。
class ReminderCoordinator {
  ReminderCoordinator({ReminderScheduler? scheduler})
    : _scheduler = scheduler ?? createDefaultReminderScheduler();

  final ReminderScheduler _scheduler;

  Future<ReminderToggleResult> setMorningReminder({
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    if (!enabled) {
      await _scheduler.cancelMorningAlarm();
      return ReminderToggleResult.disabled;
    }

    final permissionResult = await _ensurePermissions();
    if (permissionResult != null) return permissionResult;

    await _scheduler.scheduleMorningAlarm(hour, minute);
    return ReminderToggleResult.enabled;
  }

  Future<ReminderToggleResult> setEveningReminder({
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    if (!enabled) {
      await _scheduler.cancelEveningAlarm();
      return ReminderToggleResult.disabled;
    }

    final permissionResult = await _ensurePermissions();
    if (permissionResult != null) return permissionResult;

    await _scheduler.scheduleEveningAlarm(hour, minute);
    return ReminderToggleResult.enabled;
  }

  Future<ReminderToggleResult?> _ensurePermissions() async {
    await _scheduler.initialize();

    final hasNotificationPermission = await _scheduler
        .requestNotificationPermission();
    if (!hasNotificationPermission) {
      return ReminderToggleResult.notificationPermissionDenied;
    }

    final hasExactAlarmPermission = await _scheduler
        .requestExactAlarmPermission();
    if (!hasExactAlarmPermission) {
      return ReminderToggleResult.exactAlarmPermissionDenied;
    }

    return null;
  }
}
