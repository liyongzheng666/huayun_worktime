import '../core/constants/app_constants.dart';
import '../utils/date_helper.dart';
import '../utils/smart_day_type_helper.dart';
import '../utils/work_time_calculator.dart';

enum TodayWrapUpAction {
  refresh,
  importCsv,
  loginBoss,
  reviewLog,
  viewLog,
  checkAttendance,
}

enum TodayWrapUpItemStatus { complete, pending, unknown, neutral }

enum TodayBossStatus { unknown, noSession, unsubmitted, submitted }

/// 当日只读查询结果；历史缓存只作参考，不作为本次提交状态。
class TodayWrapUpData {
  const TodayWrapUpData({
    required this.date,
    this.hasEntry = false,
    this.bossStatus = TodayBossStatus.unknown,
    this.bossHours,
    this.checkedAt,
    this.cachedBossHours,
    this.cachedAt,
  });

  final DateTime date;
  final bool hasEntry;
  final TodayBossStatus bossStatus;
  final double? bossHours;

  /// 仅成功查到有效单日工时才记录此时间。
  final DateTime? checkedAt;
  final double? cachedBossHours;

  /// 现有缓存的整月同步时间，不冒充单日实时查询时间。
  final DateTime? cachedAt;

  static const freshness = Duration(minutes: 15);

  bool isFresh(DateTime now) =>
      checkedAt != null &&
      !now.isBefore(checkedAt!) &&
      now.difference(checkedAt!) < freshness;
}

class TodayWrapUpItem {
  const TodayWrapUpItem({
    required this.label,
    required this.detail,
    required this.status,
  });

  final String label;
  final String detail;
  final TodayWrapUpItemStatus status;
}

/// 纯展示决策：打卡齐全只表示记录齐全，不能推断可以下班或考勤合规。
class TodayWrapUpSummary {
  const TodayWrapUpSummary({
    required this.title,
    required this.subtitle,
    required this.attendance,
    required this.csv,
    required this.submission,
    required this.primaryAction,
    required this.actionLabel,
  });

  final String title;
  final String subtitle;
  final TodayWrapUpItem attendance;
  final TodayWrapUpItem csv;
  final TodayWrapUpItem submission;
  final TodayWrapUpAction primaryAction;
  final String actionLabel;

  static TodayWrapUpSummary compose({
    required DateTime date,
    required TodayWrapUpData data,
    Map<String, dynamic>? attendanceData,
    String? dayType,
    double? effectiveHours,
    bool attendanceLoading = false,
    bool attendanceFailed = false,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final dateMatches =
        DateHelper.formatDate(date) == DateHelper.formatDate(data.date);
    final isToday =
        DateHelper.formatDate(date) == DateHelper.formatDate(current);
    final rest =
        SmartDayTypeHelper.isRestDayType(dayType) ||
        dayType == AppConstants.typeLeave;
    final trip = dayType == AppConstants.typeBusinessTrip;
    final crossDay = attendanceData?['hasCrossDayPunch'] == true;
    final attendanceKnown =
        !attendanceLoading && !attendanceFailed && attendanceData != null;
    bool hasTime(Object? value) =>
        value is String && value.trim().isNotEmpty && value.trim() != '-';
    final checkIn = hasTime(attendanceData?['checkInTime']);
    final checkOut = hasTime(attendanceData?['checkOutTime']);
    final hasEntry = dateMatches && data.hasEntry;
    final fresh = dateMatches && data.isFresh(current) && isToday;
    final hours = data.bossHours;
    final validHours = hours != null && hours.isFinite && hours >= 0;
    final submitted =
        fresh &&
        validHours &&
        hours > 0 &&
        data.bossStatus == TodayBossStatus.submitted;
    final unsubmitted =
        fresh &&
        validHours &&
        hours == 0 &&
        data.bossStatus == TodayBossStatus.unsubmitted;
    final noSession =
        dateMatches && data.bossStatus == TodayBossStatus.noSession;
    final optionalLog =
        rest &&
        !hasEntry &&
        !checkIn &&
        !checkOut &&
        !(effectiveHours != null && effectiveHours > 0);

    final TodayWrapUpItem attendance;
    if (attendanceLoading || attendanceFailed) {
      attendance = TodayWrapUpItem(
        label: '打卡记录',
        detail: attendanceLoading ? '正在确认今天的记录…' : '暂时没查清楚，刷新后再确认',
        status: TodayWrapUpItemStatus.unknown,
      );
    } else if (crossDay) {
      attendance = const TodayWrapUpItem(
        label: '跨天打卡待核对',
        detail: '请核对记录所属日期和工时',
        status: TodayWrapUpItemStatus.pending,
      );
    } else if (rest || trip) {
      attendance = TodayWrapUpItem(
        label: '今天标记为${dayType ?? '休息'}',
        detail: trip ? '按出差安排核对工时，不按缺卡判断' : '按实际安排核对，无需为了卡片补打卡',
        status: TodayWrapUpItemStatus.neutral,
      );
    } else if (!attendanceKnown) {
      attendance = const TodayWrapUpItem(
        label: '打卡记录待确认',
        detail: '还没有查到今天的打卡记录',
        status: TodayWrapUpItemStatus.unknown,
      );
    } else if (checkIn && checkOut) {
      final hoursText = effectiveHours != null && effectiveHours.isFinite
          ? ' · ${WorkTimeCalculator.formatHours(effectiveHours)} 小时'
          : '';
      attendance = TodayWrapUpItem(
        label: '上下班记录已查到',
        detail: '请按实际班次核对$hoursText',
        status: TodayWrapUpItemStatus.complete,
      );
    } else {
      attendance = TodayWrapUpItem(
        label: checkIn
            ? '已查到上班记录'
            : checkOut
            ? '已查到下班记录'
            : '暂未查到打卡',
        detail: checkIn ? '下班记录待确认，稍后可刷新' : '请核对今天的打卡记录',
        status: TodayWrapUpItemStatus.pending,
      );
    }

    final csv = TodayWrapUpItem(
      label: hasEntry
          ? '今日日志素材已准备好'
          : optionalLog
          ? '今日暂无日志素材'
          : '今日还没有日志素材',
      detail: hasEntry
          ? '提交前再核对项目与审核人'
          : optionalLog
          ? '如今天有工作需要记录，可导入 CSV'
          : '导入包含今天日期的 CSV 后即可核对',
      status: hasEntry
          ? TodayWrapUpItemStatus.complete
          : optionalLog
          ? TodayWrapUpItemStatus.neutral
          : TodayWrapUpItemStatus.pending,
    );
    String reference = '';
    if (dateMatches &&
        data.cachedBossHours?.isFinite == true &&
        (data.cachedBossHours ?? 0) > 0) {
      final time = data.cachedAt;
      final timeText = time == null
          ? '同步时间未知'
          : '月度缓存同步于 ${DateHelper.formatDate(time)} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
      reference =
          '；上次记录已填 ${WorkTimeCalculator.formatHours(data.cachedBossHours!)} 小时（$timeText）';
    }
    final checkedAt = data.checkedAt;
    final checkedTime = checkedAt == null
        ? ''
        : '${checkedAt.hour.toString().padLeft(2, '0')}:${checkedAt.minute.toString().padLeft(2, '0')}';
    final submission = TodayWrapUpItem(
      label: submitted
          ? '今日日志已提交'
          : unsubmitted
          ? '今天尚未提交日志'
          : noSession
          ? '登录后确认提交状态'
          : '日志提交状态待确认',
      detail: submitted
          ? '$checkedTime 查到已填 ${WorkTimeCalculator.formatHours(hours)} 小时'
          : unsubmitted
          ? optionalLog
                ? '按实际工作安排决定是否需要填报'
                : '$checkedTime 已确认，核对内容后提交'
          : '${noSession ? '需要重新登录 BOSS' : '暂时没查清楚，请刷新确认'}$reference',
      status: submitted
          ? TodayWrapUpItemStatus.complete
          : unsubmitted
          ? optionalLog
                ? TodayWrapUpItemStatus.neutral
                : TodayWrapUpItemStatus.pending
          : TodayWrapUpItemStatus.unknown,
    );

    final TodayWrapUpAction action;
    final String actionLabel;
    if (!isToday || !dateMatches || crossDay) {
      action = TodayWrapUpAction.checkAttendance;
      actionLabel = '核对日期与打卡';
    } else if (noSession) {
      action = TodayWrapUpAction.loginBoss;
      actionLabel = '登录并确认';
    } else if (!submitted && !unsubmitted) {
      action = TodayWrapUpAction.refresh;
      actionLabel = '刷新确认';
    } else if (submitted) {
      action = TodayWrapUpAction.viewLog;
      actionLabel = '查看今日日志';
    } else if (optionalLog) {
      action = TodayWrapUpAction.checkAttendance;
      actionLabel = '查看今日安排';
    } else if (!hasEntry) {
      action = TodayWrapUpAction.importCsv;
      actionLabel = '导入日志素材';
    } else {
      action = TodayWrapUpAction.reviewLog;
      actionLabel = '检查并提交';
    }

    return TodayWrapUpSummary(
      title: !isToday || !dateMatches
          ? '先核对一下日期 ☕'
          : crossDay
          ? '跨天的辛苦，也要记清楚 ☕'
          : rest
          ? '按自己的节奏来 ☕'
          : submitted
          ? '日志已记好，辛苦啦 🐱'
          : '今天辛苦啦 ☕',
      subtitle: !isToday || !dateMatches
          ? '日期已经变化，请刷新今日状态'
          : crossDay
          ? '跨天记录需要单独确认，先不急着收尾'
          : submitted
          ? '打卡和工时仍请按实际安排核对'
          : rest
          ? '休息或请假按实际安排，不额外催填'
          : '看一眼进度，少惦记一件事',
      attendance: attendance,
      csv: csv,
      submission: submission,
      primaryAction: action,
      actionLabel: actionLabel,
    );
  }
}
