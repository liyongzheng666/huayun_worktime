import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/workbench_month_hours.dart';

void main() {
  final date = DateTime(2026, 9, 2);
  Map<String, dynamic> day(double hours, {String type = '工作日'}) => {
    'hours': hours,
    'type': type,
    'dataSourceStatus': 'apiConfirmed',
  };
  test('只累计截至当日，不计未来和其他月份', () {
    expect(
      WorkbenchMonthHours.calculate(
        date: date,
        cached: {
          '2026-09-01': day(8),
          '2026-09-02': day(7.5),
          '2026-09-03': day(8),
          '2026-08-31': day(8),
        },
      ),
      15.5,
    );
  });
  test('缓存缺失或含未知日期时留空而不是零', () {
    expect(WorkbenchMonthHours.calculate(date: date, cached: null), isNull);
    expect(
      WorkbenchMonthHours.calculate(date: date, cached: {'2026-09-01': day(8)}),
      isNull,
    );
    expect(
      WorkbenchMonthHours.calculate(
        date: date,
        cached: {
          '2026-09-01': day(8),
          '2026-09-02': {'hours': 0, 'type': '工作日'},
        },
      ),
      isNull,
    );
  });
  test('应用最新手工标记，休息和请假不计入工作累计', () {
    expect(
      WorkbenchMonthHours.calculate(
        date: date,
        cached: {
          '2026-09-01': day(8),
          '2026-09-02': day(8, type: '请假'),
        },
        marks: {
          '2026-09-01': {
            'type': '出差',
            'isManual': true,
            'isCustomHours': true,
            'hours': 6.5,
            'customCheckIn': '09:00',
            'customCheckOut': '16:30',
          },
        },
      ),
      6.5,
    );
  });
}
