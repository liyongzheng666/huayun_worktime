import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_service.dart';
import 'reminder_scheduler.dart';

/// iOS 打卡提醒调度器
///
/// 与 Android 的关键差异：iOS 没有「在指定时刻唤起进程执行代码」的能力，
/// 本地通知的标题和正文在**调度那一刻**就交给系统冻结了，触发时 App 进程
/// 不会被启动。因此这里只能推固定文案，无法像 Android 那样现场联网拼出
/// 「已打上班卡 08:47」这类实时内容。
///
/// 实现方式：`zonedSchedule` + `DateTimeComponents.time`，由系统按本地时间
/// 每天重复触发，App 被划掉或关机重启后依然有效，不需要额外的保活设置。
class IosReminderScheduler implements ReminderScheduler {
  IosReminderScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    NotificationService? notificationService,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _notificationService = notificationService ?? NotificationService();

  final FlutterLocalNotificationsPlugin _plugin;
  final NotificationService _notificationService;

  /// 通知 ID 与 Android 侧保持一致，方便两端排查问题。
  static const int morningNotificationId = NotificationService.morningAlarmId;
  static const int eveningNotificationId = NotificationService.eveningAlarmId;

  static const String morningTitle = '上班打卡提醒';
  static const String morningBody = '该打上班卡了，打开 App 查看今日打卡状态';
  static const String eveningTitle = '下班打卡提醒';
  static const String eveningBody = '记得检查今天的打卡和工时状态';

  static bool _timeZoneReady = false;

  @override
  Future<void> initialize() async {
    await _notificationService.initialize();
    await _ensureTimeZoneInitialized();
  }

  /// 初始化时区数据库并把本地时区设为设备当前时区。
  ///
  /// `zonedSchedule` 要求传入 `TZDateTime`；不设置本地时区的话 `tz.local`
  /// 默认是 UTC，会导致提醒时间整体偏移。
  static Future<void> _ensureTimeZoneInitialized() async {
    if (_timeZoneReady) return;

    tz_data.initializeTimeZones();
    try {
      final timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));
    } catch (_) {
      // 取不到设备时区时回退到东八区，避免整个提醒功能不可用。
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    }
    _timeZoneReady = true;
  }

  @override
  Future<bool> requestNotificationPermission() {
    return _notificationService.requestNotificationPermission();
  }

  /// iOS 没有精确闹钟权限这个概念，直接放行，交给上层继续走调度。
  @override
  Future<bool> requestExactAlarmPermission() async => true;

  @override
  Future<void> scheduleMorningAlarm(int hour, int minute) async {
    await _scheduleDaily(
      id: morningNotificationId,
      title: morningTitle,
      body: morningBody,
      hour: hour,
      minute: minute,
    );
  }

  @override
  Future<void> scheduleEveningAlarm(int hour, int minute) async {
    await _scheduleDaily(
      id: eveningNotificationId,
      title: eveningTitle,
      body: eveningBody,
      hour: hour,
      minute: minute,
    );
  }

  /// 发送测试通知：延迟若干秒后触发一次。
  ///
  /// 不走 `ReminderScheduler` 接口，因为这是纯调试能力，两端实现方式差异很大：
  /// Android 靠 AlarmManager 唤醒进程，iOS 只能预约一条系统通知。
  Future<void> scheduleTestNotification({
    Duration delay = const Duration(seconds: 10),
  }) async {
    await _ensureTimeZoneInitialized();
    await _plugin.cancel(NotificationService.testAlarmId);

    await _plugin.zonedSchedule(
      NotificationService.testAlarmId,
      '🔔 测试通知',
      '提醒功能工作正常，实际提醒会在你设置的时间推送',
      tz.TZDateTime.now(tz.local).add(delay),
      _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancelMorningAlarm() async {
    await _plugin.cancel(morningNotificationId);
  }

  @override
  Future<void> cancelEveningAlarm() async {
    await _plugin.cancel(eveningNotificationId);
  }

  Future<void> _scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {
    await _ensureTimeZoneInitialized();
    await _plugin.cancel(id);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      nextInstanceOf(hour, minute),
      _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      // 只匹配「时:分」，系统据此每天重复触发。
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  NotificationDetails _details() {
    return const NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        // 时效性通知：可穿透专注模式，需在 Xcode 勾选
        // Time Sensitive Notifications capability 才生效。
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  /// 计算下一次触发时刻：今天该时间点已过则顺延到明天。
  static tz.TZDateTime nextInstanceOf(int hour, int minute, {DateTime? now}) {
    final localNow = now == null
        ? tz.TZDateTime.now(tz.local)
        : tz.TZDateTime.from(now, tz.local);

    var scheduled = tz.TZDateTime(
      tz.local,
      localNow.year,
      localNow.month,
      localNow.day,
      hour,
      minute,
    );

    if (!scheduled.isAfter(localNow)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}
