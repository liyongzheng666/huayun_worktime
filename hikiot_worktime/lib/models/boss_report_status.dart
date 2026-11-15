/// 单日填报状态与工时数值分开：零合计不展示成一条“已填0小时”的日报。
enum BossReportState { unknown, unreported, reported, recordNeedsReview }

class BossReportStatus {
  const BossReportStatus({
    required this.hours,
    required this.confirmed,
    this.hasKnownRecord = false,
  });

  final double? hours;
  final bool confirmed;
  // 已缓存的记录ID只能提示记录存在的线索，零合计时仍需核对，不能断言未填。
  final bool hasKnownRecord;

  bool get hasPositiveHours => hours != null && hours!.isFinite && hours! > 0;

  BossReportState get state {
    if (!confirmed || hours == null || !hours!.isFinite || hours! < 0) {
      return BossReportState.unknown;
    }
    if (hasPositiveHours) return BossReportState.reported;
    return hasKnownRecord
        ? BossReportState.recordNeedsReview
        : BossReportState.unreported;
  }

  String get statusText => switch (state) {
    BossReportState.unknown => '待确认',
    BossReportState.unreported => '未填报',
    BossReportState.reported => '已填报',
    BossReportState.recordNeedsReview => '已有日报记录，工时待核对',
  };
}
