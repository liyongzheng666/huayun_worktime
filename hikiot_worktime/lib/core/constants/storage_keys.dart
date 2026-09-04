/// 本地存储Key常量
/// 统一管理SharedPreferences中的所有key，避免魔法字符串
class StorageKeys {
  StorageKeys._();

  // ============ 认证相关 ============
  /// 用户Token
  static const String token = 'hikiot_token';

  /// 用户名
  static const String userName = 'user_name';

  /// 员工编号
  static const String personNo = 'personNo';

  /// 团队编号
  static const String teamNo = 'teamNo';

  /// 团队名称
  static const String teamName = 'team_name';

  /// 选中的团队
  static const String selectedTeam = 'selected_team';

  // ============ 设置相关 ============
  /// 通用设置
  static const String settings = 'settings';

  /// 午休开始时间
  static const String lunchStartTime = 'lunch_start_time';

  /// 午休结束时间
  static const String lunchEndTime = 'lunch_end_time';

  /// 跨天时间点（分钟）
  static const String crossDayMinutes = 'cross_day_minutes';

  /// 基础目标百分比
  static const String baseTarget = 'base_target';

  /// 最低目标百分比（目标进度列表的起点）
  static const String minTarget = 'min_target';

  /// 置顶目标
  static const String pinnedTarget = 'pinned_target';

  /// 扩展目标范围开关
  static const String extendedTargetRange = 'extended_target_range';

  /// 开发者工具开关
  static const String debugToolsEnabled = 'debug_tools_enabled';

  // ============ 震动设置 ============
  /// 震动模式
  static const String hapticMode = 'haptic_mode';

  // ============ 数据缓存 ============
  /// 日历标记前缀 (实际key: calendar_marks_{teamNo})
  static const String calendarMarksPrefix = 'calendar_marks';

  /// 月度数据前缀 (实际key: monthly_data_{teamNo}_{month})
  static const String monthlyDataPrefix = 'monthly_data';

  /// 节假日计划
  static const String holidayPlan = 'holiday_plan';

  // ============ 提醒相关 ============
  /// 上班提醒开关
  static const String morningReminderEnabled = 'morning_reminder_enabled';

  /// 下班提醒开关
  static const String eveningReminderEnabled = 'evening_reminder_enabled';

  /// 上班提醒时间
  static const String morningReminderTime = 'morning_reminder_time';

  /// 下班提醒时间
  static const String eveningReminderTime = 'evening_reminder_time';

  // ============ 工作日志相关 ============
  /// 导入的工作日志条目（按日期归档的 JSON）
  static const String workLogEntries = 'work_log_entries';

  /// 工作日志导入来源文件名
  static const String workLogSourceName = 'work_log_source_name';

  /// 工作日志导入时间（ISO8601）
  static const String workLogImportedAt = 'work_log_imported_at';

  /// BOSS 提交所需的固定业务标识（项目 ID/编码、审核人 ID）。
  /// 只存业务标识，不存 Password、LoginID 等会话凭据。
  static const String workLogBossConstants = 'work_log_boss_constants';

  /// CSV 项目名 → 该项目的 BOSS 提交配置。
  ///
  /// 与上面那份「最近一次使用的配置」并存，是有意的：上面只存得下一个项目，
  /// 用户在两个项目之间来回切时，每次都会把对方的配置覆盖掉，于是
  /// 「确认后就记住」永远兑现不了。这份按 CSV 项目名分开存，切回来就还在。
  static const String workLogProjectBindings = 'work_log_project_bindings';

  /// App 成功创建的日志：日期 → BOSS `WORKLOG_xxx`。
  ///
  /// 只保存业务记录 ID，不保存从网页会话取得的对象详情或登录凭据。
  static const String workLogObjectIds = 'work_log_object_ids';

  /// 最近一次成功登录 BOSS 的用户名。密码永不落盘。
  static const String bossLoginUserName = 'boss_login_user_name';

  /// BOSS 月度已填工时前缀 (实际key: boss_hours_{yyyy-MM})
  static const String bossHoursPrefix = 'boss_hours';

  /// BOSS 月度工时最近一次完整刷新时间前缀。
  static const String bossHoursRefreshedAtPrefix = 'boss_hours_refreshed_at';

  /// 获取 BOSS 月度工时的完整 key
  static String bossHoursKey(String monthKey) => '${bossHoursPrefix}_$monthKey';

  static String bossHoursRefreshedAtKey(String monthKey) =>
      '${bossHoursRefreshedAtPrefix}_$monthKey';

  // ============ 引导相关 ============
  /// 新手引导完成标记
  static const String onboardingCompleted = 'onboarding_completed';

  /// 免责声明确认标记
  static const String disclaimerAccepted = 'disclaimer_accepted';

  /// 首次提醒引导完成标记
  static const String reminderGuideShown = 'reminder_guide_shown';

  // ============ 辅助方法 ============
  /// 获取日历标记的完整key
  static String calendarMarksKey(String teamNo) =>
      '${calendarMarksPrefix}_$teamNo';

  /// 获取月度数据的完整key
  static String monthlyDataKey(String teamNo, String month) =>
      '${monthlyDataPrefix}_${teamNo}_$month';
}
