import '../core/constants/constants.dart';
import 'calendar_mark_merge.dart';
import 'date_helper.dart';
import 'smart_day_type_helper.dart';

/// 复用月度缓存与手工标记；数据不全时留空，不把部分累计伪装为整月结果。
class WorkbenchMonthHours {
  static double? calculate({
    required DateTime date,
    required Map<String, Map<String, dynamic>>? cached,
    Map<String, Map<String, dynamic>> marks = const {},
  }) {
    if (cached == null) return null;
    var total = 0.0;
    for (var day = 1; day <= date.day; day++) {
      final key = DateHelper.formatDate(DateTime(date.year, date.month, day));
      final raw = cached[key];
      if (raw == null) return null;
      final value = marks[key] == null
          ? raw
          : CalendarMarkMerge.applyMark(raw, marks[key]!);
      if (value['isManual'] != true &&
          SmartDayTypeHelper.parseDataSourceStatus(value['dataSourceStatus']) !=
              DayDataSourceStatus.apiConfirmed) {
        return null;
      }
      final type = value['type'];
      if (type is! String) return null;
      if (type == AppConstants.typeLeave ||
          SmartDayTypeHelper.isRestDayType(type)) {
        continue;
      }
      final hours = value['hours'];
      if (hours is! num || !hours.isFinite || hours < 0) return null;
      total += hours.toDouble();
    }
    return total;
  }
}
