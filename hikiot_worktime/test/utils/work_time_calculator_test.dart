import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_time_calculator.dart';

void main() {
  group('WorkTimeCalculator', () {
    setUp(() {
      WorkTimeCalculator.lunchStartMinutes = 12 * 60;
      WorkTimeCalculator.lunchEndMinutes = 13 * 60;
    });

    tearDown(() {
      WorkTimeCalculator.lunchStartMinutes = 12 * 60;
      WorkTimeCalculator.lunchEndMinutes = 13 * 60;
    });

    test('uses configured lunch duration for lunch deduction', () {
      WorkTimeCalculator.lunchStartMinutes = 12 * 60;
      WorkTimeCalculator.lunchEndMinutes = 12 * 60 + 45;

      expect(WorkTimeCalculator.getLunchDeductionMinutes(9 * 60, 18 * 60), 45);
    });

    test('does not add time when lunch end is before lunch start', () {
      WorkTimeCalculator.lunchStartMinutes = 13 * 60;
      WorkTimeCalculator.lunchEndMinutes = 12 * 60;

      expect(WorkTimeCalculator.lunchDurationMinutes, 0);
      expect(WorkTimeCalculator.getLunchDeductionMinutes(9 * 60, 18 * 60), 0);
      expect(WorkTimeCalculator.calculateWorkHoursStr('09:00', '18:00'), 9.0);
    });

    test('deducts lunch for work sessions that end after midnight', () {
      expect(WorkTimeCalculator.calculateWorkHoursStr('09:00', '00:30'), 14.5);
      expect(WorkTimeCalculator.calculateWorkHoursStr('12:30', '00:30'), 11.5);
      expect(WorkTimeCalculator.calculateWorkHoursStr('21:00', '00:30'), 3.5);
    });

    test('keeps integer values compact and truncates decimal values', () {
      expect(WorkTimeCalculator.formatHours(0), '0');
      expect(WorkTimeCalculator.formatHours(8), '8');
      expect(WorkTimeCalculator.formatHours(0.0), '0.00');
      expect(WorkTimeCalculator.formatHours(8.0), '8.00');
      expect(WorkTimeCalculator.formatHours(5.559), '5.55');
    });
  });

  group('parseHoursInput 手输工时校验', () {
    test('正常输入按截断保留两位，不四舍五入', () {
      // 与 formatHours 同一口径：5.559 -> 5.55 而不是 5.56
      expect(WorkTimeCalculator.parseHoursInput('8'), 8);
      expect(WorkTimeCalculator.parseHoursInput('8.5'), 8.5);
      expect(WorkTimeCalculator.parseHoursInput('5.559'), 5.55);
      expect(WorkTimeCalculator.parseHoursInput(' 10.75 '), 10.75);
    });

    test('非法输入一律返回 null，不放脏值进公司系统', () {
      expect(WorkTimeCalculator.parseHoursInput(''), isNull);
      expect(WorkTimeCalculator.parseHoursInput('   '), isNull);
      expect(WorkTimeCalculator.parseHoursInput('abc'), isNull);
      expect(WorkTimeCalculator.parseHoursInput('八小时'), isNull);
    });

    test('0 和负数不合法：提交 0 工时的日志没有意义', () {
      expect(WorkTimeCalculator.parseHoursInput('0'), isNull);
      expect(WorkTimeCalculator.parseHoursInput('-3'), isNull);
    });

    test('超过 24 小时必然是笔误', () {
      expect(WorkTimeCalculator.parseHoursInput('24'), 24);
      expect(WorkTimeCalculator.parseHoursInput('24.01'), isNull);
      expect(WorkTimeCalculator.parseHoursInput('100'), isNull);
    });
  });
}
