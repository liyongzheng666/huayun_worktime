import '../utils/decimal_hours.dart';

/// 月度差额无法继续分配时，提示用户核对已有日报。
enum MonthlyReportProblem { overReported, noPendingDates, capacityExceeded }

/// 月度填报建议，全部工时以 0.01 小时为单位保存。
///
/// [remainder] 是尚不足 0.1 小时的尾差；只计算它，不在这里决定何时舍弃。
/// [problem] 非空时不提供建议，避免把无法平衡的结果带入提交确认。
class MonthlyReportPlan {
  const MonthlyReportPlan({
    required this.actualTotal,
    required this.reportedTotal,
    required this.remainingTotal,
    required this.remainder,
    required this.pendingActual,
    required this.suggestions,
    this.problem,
  });

  final int actualTotal;
  final int reportedTotal;
  final int remainingTotal;
  final int remainder;
  final Map<String, int> pendingActual;
  final Map<String, int> suggestions;
  final MonthlyReportProblem? problem;

  bool get isActionable => problem == null && suggestions.isNotEmpty;
}

/// 在整月额度约束下，以 0.1 小时为步长调整未填日期。
///
/// 调用方负责确认考勤与已填报数据完整、有效。本类只处理确定的整数工时，
/// 不读缓存、不改原始考勤，也不写入或重新提交已有日报。
class MonthlyReportBalance {
  MonthlyReportBalance._();

  static const int _step = 10;
  static const int _maxDayUnits = 240;

  static MonthlyReportPlan calculate({
    required Map<String, int> actualByDate,
    required Map<String, int> reportedByDate,
  }) {
    _validateHours(actualByDate);
    _validateHours(reportedByDate);
    final actualTotal = actualByDate.values.fold(0, (a, b) => a + b);
    final reportedTotal = reportedByDate.values.fold(0, (a, b) => a + b);
    final remainingTotal = actualTotal - reportedTotal;
    final dates =
        actualByDate.keys
            .where(
              (date) =>
                  actualByDate[date]! > 0 && !reportedByDate.containsKey(date),
            )
            .toList()
          ..sort();
    final pending = Map<String, int>.unmodifiable({
      for (final date in dates) date: actualByDate[date]!,
    });

    MonthlyReportPlan result({
      MonthlyReportProblem? problem,
      Map<String, int> suggestions = const {},
    }) => MonthlyReportPlan(
      actualTotal: actualTotal,
      reportedTotal: reportedTotal,
      remainingTotal: remainingTotal,
      remainder: remainingTotal >= 0 ? remainingTotal % _step : 0,
      pendingActual: pending,
      suggestions: Map<String, int>.unmodifiable(suggestions),
      problem: problem,
    );

    if (remainingTotal < 0) {
      return result(problem: MonthlyReportProblem.overReported);
    }
    if (dates.isEmpty) {
      return result(
        problem: remainingTotal == 0
            ? null
            : MonthlyReportProblem.noPendingDates,
      );
    }
    final targetUnits = remainingTotal ~/ _step;
    if (targetUnits > dates.length * _maxDayUnits) {
      return result(problem: MonthlyReportProblem.capacityExceeded);
    }

    // 从各天向下取整开始；每次选择平方误差增加最少的一天加减 0.1 小时。
    // 步长相同，比较「原值 - 当前建议」即可，计算全程不需要浮点数。
    final units = <String, int>{};
    var allocatedUnits = 0;
    for (final date in dates) {
      final initial = pending[date]! ~/ _step;
      units[date] = initial > _maxDayUnits ? _maxDayUnits : initial;
      allocatedUnits += units[date]!;
    }
    while (allocatedUnits != targetUnits) {
      final adding = allocatedUnits < targetUnits;
      String? chosen;
      int? chosenGap;
      for (final date in dates) {
        final current = units[date]!;
        if (adding ? current >= _maxDayUnits : current == 0) continue;
        final gap = pending[date]! - current * _step;
        if (chosenGap == null || (adding ? gap > chosenGap : gap < chosenGap)) {
          chosen = date;
          chosenGap = gap;
        }
      }
      // 上面的非负额度与容量检查保证必有可调整日期。
      if (chosen == null) throw StateError('月度填报额度无法分配');
      final change = adding ? 1 : -1;
      units[chosen] = units[chosen]! + change;
      allocatedUnits += change;
    }
    return result(
      suggestions: {for (final date in dates) date: units[date]! * _step},
    );
  }

  /// 已经是百分之一小时的整数，直接格式化，避免再乘浮点数造成少一分。
  static String formatHundredths(int value) =>
      DecimalHours.formatHundredths(value);

  static void _validateHours(Map<String, int> values) {
    for (final entry in values.entries) {
      if (entry.key.isEmpty || entry.value < 0) {
        throw ArgumentError.value(values, 'values', '日期不能为空，工时不能为负');
      }
    }
  }
}
