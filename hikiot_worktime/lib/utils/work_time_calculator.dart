import '../core/constants/constants.dart';
import '../services/storage_service.dart';

/// 工时计算工具类
/// 统一管理午休扣除逻辑和工时计算
class WorkTimeCalculator {
  // 默认午休时间配置
  static const String defaultLunchStart = '12:00';
  static const String defaultLunchEnd = '13:00';
  static const int defaultLunchDurationMinutes = 60;

  // 默认午休时间（分钟表示，方便计算）
  static int lunchStartMinutes = 12 * 60; // 12:00 = 720分钟
  static int lunchEndMinutes = 13 * 60; // 13:00 = 780分钟

  // 是否已初始化
  static bool _initialized = false;

  /// 初始化午休时间配置（从设置加载）
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final settings = await StorageService().loadSettings();
      final lunchStart = settings[StorageKeys.lunchStartTime] as String?;
      final lunchEnd = settings[StorageKeys.lunchEndTime] as String?;

      if (lunchStart != null) {
        final minutes = parseTimeToMinutes(lunchStart);
        if (minutes != null) lunchStartMinutes = minutes;
      }

      if (lunchEnd != null) {
        final minutes = parseTimeToMinutes(lunchEnd);
        if (minutes != null) lunchEndMinutes = minutes;
      }

      _initialized = true;
    } catch (e) {
      // Initialization error - use defaults
    }
  }

  /// 重新加载配置（设置更改后调用）
  static Future<void> reload() async {
    _initialized = false;
    await initialize();
  }

  /// 获取当前午休时长（分钟）
  static int get lunchDurationMinutes {
    final duration = lunchEndMinutes - lunchStartMinutes;
    return duration > 0 ? duration : 0;
  }

  /// 判断是否应该扣除午休时间
  /// 规则：上班时间 < 午休开始 且 下班时间 > 午休结束 时才扣除
  ///
  /// [checkInMinutes] 上班时间（分钟，如 8:30 = 510）
  /// [checkOutMinutes] 下班时间（分钟，如 17:30 = 1050）
  ///
  /// 返回：是否需要扣除午休
  static bool shouldDeductLunch(int checkInMinutes, int checkOutMinutes) {
    if (lunchEndMinutes <= lunchStartMinutes) return false;
    final comparableCheckOut = _comparableCheckOutMinutes(
      checkInMinutes,
      checkOutMinutes,
    );
    return checkInMinutes < lunchStartMinutes &&
        comparableCheckOut > lunchEndMinutes;
  }

  /// 判断是否应该扣除午休时间（字符串版本）
  ///
  /// [checkIn] 上班时间，格式 "HH:mm"
  /// [checkOut] 下班时间，格式 "HH:mm"
  ///
  /// 返回：是否需要扣除午休
  static bool shouldDeductLunchStr(String checkIn, String checkOut) {
    final inMinutes = parseTimeToMinutes(checkIn);
    final outMinutes = parseTimeToMinutes(checkOut);

    if (inMinutes == null || outMinutes == null) return false;

    return shouldDeductLunch(inMinutes, outMinutes);
  }

  /// 计算实际需要扣除的午休分钟数
  /// 考虑部分重叠的情况（为将来扩展预留）
  ///
  /// [checkInMinutes] 上班时间（分钟）
  /// [checkOutMinutes] 下班时间（分钟）
  ///
  /// 返回：需要扣除的分钟数
  static int getLunchDeductionMinutes(int checkInMinutes, int checkOutMinutes) {
    if (shouldDeductLunch(checkInMinutes, checkOutMinutes)) {
      return lunchDurationMinutes;
    }
    return 0;
  }

  /// 计算工时（分钟）
  ///
  /// [checkInMinutes] 上班时间（分钟）
  /// [checkOutMinutes] 下班时间（分钟）
  /// [deductLunch] 是否扣除午休，默认自动判断
  ///
  /// 返回：工时分钟数
  static int calculateWorkMinutes(
    int checkInMinutes,
    int checkOutMinutes, {
    bool? deductLunch,
  }) {
    final comparableCheckOut = _comparableCheckOutMinutes(
      checkInMinutes,
      checkOutMinutes,
    );

    // 处理下班时间在午休期间的情况：截断到12:00
    int effectiveCheckOut = checkOutMinutes;
    if (checkInMinutes < lunchStartMinutes &&
        comparableCheckOut >= lunchStartMinutes &&
        comparableCheckOut <= lunchEndMinutes) {
      effectiveCheckOut = lunchStartMinutes;
    }

    // 处理上班时间在午休期间的情况：截断到13:00
    int effectiveCheckIn = checkInMinutes;
    if (checkInMinutes >= lunchStartMinutes &&
        checkInMinutes <= lunchEndMinutes &&
        comparableCheckOut > lunchEndMinutes) {
      effectiveCheckIn = lunchEndMinutes;
    }

    var totalMinutes = effectiveCheckOut - effectiveCheckIn;

    // 处理跨天情况
    if (totalMinutes < 0) {
      totalMinutes += 24 * 60;
    }

    // 判断是否扣除午休（上班<午休开始且下班>午休结束）
    final shouldDeduct =
        deductLunch ?? shouldDeductLunch(effectiveCheckIn, effectiveCheckOut);
    if (shouldDeduct) {
      totalMinutes -= lunchDurationMinutes;
    }

    return totalMinutes;
  }

  static int _comparableCheckOutMinutes(
    int checkInMinutes,
    int checkOutMinutes,
  ) {
    if (checkOutMinutes < checkInMinutes) {
      return checkOutMinutes + 24 * 60;
    }
    return checkOutMinutes;
  }

  /// 计算工时（小时，保留2位小数）
  ///
  /// [checkInMinutes] 上班时间（分钟）
  /// [checkOutMinutes] 下班时间（分钟）
  /// [deductLunch] 是否扣除午休，默认自动判断
  ///
  /// 返回：工时小时数（截断到2位小数）
  static double calculateWorkHours(
    int checkInMinutes,
    int checkOutMinutes, {
    bool? deductLunch,
  }) {
    final minutes = calculateWorkMinutes(
      checkInMinutes,
      checkOutMinutes,
      deductLunch: deductLunch,
    );
    final hours = minutes / 60.0;
    // 截断到2位小数
    return (hours * 100).truncateToDouble() / 100;
  }

  /// 从字符串计算工时（小时）
  ///
  /// [checkIn] 上班时间，格式 "HH:mm"
  /// [checkOut] 下班时间，格式 "HH:mm"
  /// [deductLunch] 是否扣除午休，默认自动判断
  ///
  /// 返回：工时小时数（截断到2位小数），解析失败返回0.0
  static double calculateWorkHoursStr(
    String checkIn,
    String checkOut, {
    bool? deductLunch,
  }) {
    final inMinutes = parseTimeToMinutes(checkIn);
    final outMinutes = parseTimeToMinutes(checkOut);

    if (inMinutes == null || outMinutes == null) return 0.0;

    return calculateWorkHours(inMinutes, outMinutes, deductLunch: deductLunch);
  }

  /// 解析时间字符串为分钟数
  ///
  /// [timeStr] 时间字符串，格式 "HH:mm" 或 "HH:MM:SS"
  ///
  /// 返回：从0点开始的分钟数，解析失败返回null
  static int? parseTimeToMinutes(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return null;

    try {
      final parts = timeStr.split(':');
      if (parts.length < 2) return null;

      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);

      return hour * 60 + minute;
    } catch (e) {
      return null;
    }
  }

  /// 将分钟数转换为时间字符串
  ///
  /// [minutes] 从0点开始的分钟数
  ///
  /// 返回：格式 "HH:mm"
  static String minutesToTimeStr(int minutes) {
    final hour = (minutes ~/ 60) % 24;
    final minute = minutes % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// 格式化工时显示
  ///
  /// [hours] 工时小时数
  ///
  /// 返回：格式化的字符串，如 "8.55" (直接截断2位，不四舍五入)
  static String formatHours(num hours) {
    // 整数保持紧凑显示；浮点运算结果保留两位小数，直接截断不四舍五入。
    // 例如: 8 -> 8
    if (hours is int) {
      return hours.toString();
    }

    // 例如: 8.0 -> 8.00
    // 例如: 5.559 (double) -> 5.55
    final h = hours.toDouble();
    final truncated = (h * 100).truncateToDouble() / 100;
    return truncated.toStringAsFixed(2);
  }

  /// 解析用户手输的工时，非法输入返回 null。
  ///
  /// 提交 BOSS 日志前允许手工调整工时（打卡异常、出差、补录等场景），
  /// 但不能把非法值发到公司系统，因此在这里统一校验。
  ///
  /// 规则与 [formatHours] 一致：保留两位小数，**截断不四舍五入**。
  /// 上限取一天 24 小时，超出必然是笔误。
  static double? parseHoursInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final value = double.tryParse(text);
    if (value == null || value <= 0 || value > 24) return null;

    return (value * 100).truncateToDouble() / 100;
  }

  /// 打卡工时与 BOSS 已填工时的一致性容差。
  ///
  /// BOSS 那边只保留一位小数，且截断与四舍五入都出现过：
  /// 打卡 11.47 在 BOSS 里可能是 11.4（截断），也可能是 11.5（四舍五入）。
  /// 这两种都属于正常精度损失，不是填错，不该报警。
  static const double bossHoursTolerance = 0.1;

  /// 判断打卡工时与 BOSS 已填工时是否算一致。
  ///
  /// 只有超出 [bossHoursTolerance] 才认为真的对不上——
  /// 把一位小数的精度差当成异常，会让整屏都是无意义的警示，
  /// 反而把真正填错的那天淹没掉。
  static bool isBossHoursConsistent(double punchHours, double bossHours) {
    // 加极小量抵消浮点误差，避免 11.5 与 11.4 这类恰好等于容差的情况被误判
    return (punchHours - bossHours).abs() <= bossHoursTolerance + 1e-9;
  }

  // ========== BOSS 工时凑整刻度 ==========

  /// BOSS 填报工时的刻度：0.1 小时，正好等于 6 分钟。
  ///
  /// BOSS 只保留一位小数，零头会被吃掉——打卡 11.55 报上去零头就没了。
  /// 刻度用整数分钟表示，顺带避开 0.1 在二进制下不可精确表示的误差。
  static const int bossHoursStepMinutes = 6;

  /// 把工时还原成整数分钟。
  ///
  /// **必须向上取整而不是四舍五入**：工时是「分钟 ÷ 60 再截断两位」的结果，
  /// 截断永远让数值偏小（69 分钟存成 1.14 小时），直接 round 会掉回 68 分钟，
  /// 「还差几分钟」就整条错一分钟。减去极小量是防止 693.0 这类
  /// 刚好落在整数上的值被浮点误差抬成 694。
  static int hoursToMinutes(double hours) => (hours * 60 - 1e-6).ceil();

  /// 距离下一个 [bossHoursStepMinutes] 刻度还差几分钟。
  ///
  /// 已经落在刻度上时返回 0，不返回 6——那会让用户凭空多等一档。
  static int minutesToNextBossStep(double hours) {
    final remainder = hoursToMinutes(hours) % bossHoursStepMinutes;
    return remainder == 0 ? 0 : bossHoursStepMinutes - remainder;
  }

  /// 下一个刻度对应的工时；已落在刻度上则返回自身。
  static double nextBossStepHours(double hours) {
    final minutes = hoursToMinutes(hours) + minutesToNextBossStep(hours);
    return minutes / 60.0;
  }

  // ========== 目标管理逻辑 (KISS: 复用此类) ==========

  /// 生成目标进度列表：从 [minTarget] 起，按 10% 递增，到 [baseTarget] 为止。
  ///
  /// 从小到大排列，因此基础目标天然落在最后一项。
  ///
  /// 为什么不再固定输出 100~160：100%、110% 这类挡位常年满足，
  /// 排在最前面只会挤占版面，把真正要冲的挡位推到看不见的地方。
  /// 起点与终点都由用户在设置里决定。
  ///
  /// [minTarget] 高于 [baseTarget] 时只返回基础目标——
  /// 这是设置被改乱的情况，此时至少要让用户看见自己的基础目标，
  /// 返回空列表会让整个进度区消失，更难排查。
  static List<int> generateTargetList(int baseTarget, {int? minTarget}) {
    final start = minTarget ?? AppConstants.defaultMinTarget;
    if (start > baseTarget) return [baseTarget];

    final targets = <int>{};
    for (var value = start; value < baseTarget; value += AppConstants.targetStep) {
      targets.add(value);
    }
    targets.add(baseTarget); // 基础目标必定在列表中，且为最后一项

    return targets.toList()..sort();
  }

  /// 计算新的置顶目标（切换逻辑）
  ///
  /// [currentTarget] 当前置顶目标
  /// [targetToToggle] 想要切换的目标
  ///
  /// 返回：新的置顶目标（如果相同则取消置顶返回null，否则返回新目标）
  static int? calculateNewPinnedTarget(int? currentTarget, int targetToToggle) {
    return currentTarget == targetToToggle ? null : targetToToggle;
  }
}
