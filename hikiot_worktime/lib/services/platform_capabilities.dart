import 'dart:io' show Platform;

/// 平台能力探测
///
/// 职责单一：集中回答「当前平台能做什么」，避免 `Platform.isAndroid` 这类判断
/// 散落到页面和服务里。新增平台差异时只改这一个文件。
///
/// 之所以按「能力」而不是按「平台名」暴露，是因为调用方关心的是
/// 「能不能在后台联网拿实时打卡状态」，而不是「是不是安卓」。
class PlatformCapabilities {
  PlatformCapabilities._();

  /// 测试注入点：非 null 时覆盖真实平台判断。
  static PlatformCapabilitiesOverride? debugOverride;

  /// 是否支持精确闹钟唤醒后台联网。
  ///
  /// Android 通过 AlarmManager 可以在指定时刻唤起后台 isolate 执行任意代码；
  /// iOS 没有等价能力，本地通知的内容在调度那一刻就已冻结。
  static bool get supportsExactBackgroundAlarm =>
      debugOverride?.supportsExactBackgroundAlarm ?? Platform.isAndroid;

  /// 提醒文案能否携带实时打卡状态。
  ///
  /// 只有能在触发时刻执行代码的平台才做得到；否则只能推固定文案。
  static bool get supportsLiveReminderContent => supportsExactBackgroundAlarm;

  /// 是否需要引导用户设置厂商保活（自启动、省电优化白名单）。
  ///
  /// 仅国产 Android ROM 需要；iOS 由系统统一调度通知，没有这些设置项。
  static bool get needsVendorKeepAliveGuide =>
      debugOverride?.needsVendorKeepAliveGuide ?? Platform.isAndroid;

  /// 是否需要申请精确闹钟权限（Android 12+ 的 SCHEDULE_EXACT_ALARM）。
  static bool get needsExactAlarmPermission => supportsExactBackgroundAlarm;
}

/// 平台能力覆盖值，仅用于测试。
class PlatformCapabilitiesOverride {
  const PlatformCapabilitiesOverride({
    required this.supportsExactBackgroundAlarm,
    required this.needsVendorKeepAliveGuide,
  });

  /// 模拟 Android：具备全部后台闹钟能力。
  const PlatformCapabilitiesOverride.android()
    : supportsExactBackgroundAlarm = true,
      needsVendorKeepAliveGuide = true;

  /// 模拟 iOS：只能推固定文案的本地通知。
  const PlatformCapabilitiesOverride.ios()
    : supportsExactBackgroundAlarm = false,
      needsVendorKeepAliveGuide = false;

  final bool supportsExactBackgroundAlarm;
  final bool needsVendorKeepAliveGuide;
}
