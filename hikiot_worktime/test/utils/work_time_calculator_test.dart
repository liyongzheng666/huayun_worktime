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

  group('isBossHoursConsistent 打卡与 BOSS 的一致性容差', () {
    test('BOSS 截断到一位小数不算不一致', () {
      // 打卡 11.47 在 BOSS 里显示 11.4（截断），属正常精度损失
      expect(WorkTimeCalculator.isBossHoursConsistent(11.47, 11.4), isTrue);
    });

    test('BOSS 四舍五入到一位小数也不算不一致', () {
      // 同一个 11.47 也可能被记成 11.5
      expect(WorkTimeCalculator.isBossHoursConsistent(11.47, 11.5), isTrue);
    });

    test('完全相同自然一致', () {
      expect(WorkTimeCalculator.isBossHoursConsistent(8, 8), isTrue);
      expect(WorkTimeCalculator.isBossHoursConsistent(10.7, 10.7), isTrue);
    });

    test('恰好差 0.1 仍按一致处理，不被浮点误差判死', () {
      expect(WorkTimeCalculator.isBossHoursConsistent(11.5, 11.4), isTrue);
      expect(WorkTimeCalculator.isBossHoursConsistent(11.4, 11.5), isTrue);
    });

    test('超出容差才算真的对不上', () {
      // 这才是需要提醒用户去核对的情况
      expect(WorkTimeCalculator.isBossHoursConsistent(11.47, 10.7), isFalse);
      expect(WorkTimeCalculator.isBossHoursConsistent(11.06, 10.7), isFalse);
      expect(WorkTimeCalculator.isBossHoursConsistent(9.93, 10.3), isFalse);
      expect(WorkTimeCalculator.isBossHoursConsistent(8, 4), isFalse);
    });
  });

  group('BOSS 工时凑整刻度', () {
    test('工时还原成分钟不能被截断误差带偏一分钟', () {
      // 工时是「分钟/60 截断两位」的结果，截断永远让数值偏小：
      // 69 分钟存成 1.14 小时，四舍五入会掉回 68 分钟，
      // 「还差几分钟」就会整条算错。
      expect(WorkTimeCalculator.hoursToMinutes(1.14), 69);
      expect(WorkTimeCalculator.hoursToMinutes(11.55), 693);
      expect(WorkTimeCalculator.hoursToMinutes(11.6), 696);
      expect(WorkTimeCalculator.hoursToMinutes(8), 480);
    });

    test('全天每一分钟都能从截断后的工时精确还原', () {
      // 这条覆盖 24 小时内所有分钟，防止再冒出第二个 69 分钟那样的个例
      for (var m = 0; m <= 24 * 60; m++) {
        final truncated = (m / 60.0 * 100).truncateToDouble() / 100;
        expect(
          WorkTimeCalculator.hoursToMinutes(truncated),
          m,
          reason: '$m 分钟被还原错了',
        );
      }
    });

    test('11.55 距离 11.6 还差 3 分钟', () {
      expect(WorkTimeCalculator.minutesToNextBossStep(11.55), 3);
      expect(
        WorkTimeCalculator.formatHours(
          WorkTimeCalculator.nextBossStepHours(11.55),
        ),
        '11.60',
      );
    });

    test('已经落在 0.1 刻度上时不需要再等', () {
      expect(WorkTimeCalculator.minutesToNextBossStep(11.6), 0);
      expect(WorkTimeCalculator.minutesToNextBossStep(8), 0);
      expect(WorkTimeCalculator.minutesToNextBossStep(8.5), 0);
    });

    test('落在刻度上时下一档就是自身，不会白跳一档', () {
      // 跳到 11.7 会让用户凭空多等 6 分钟
      expect(
        WorkTimeCalculator.formatHours(
          WorkTimeCalculator.nextBossStepHours(11.6),
        ),
        '11.60',
      );
    });

    test('差值恒在 1 到 5 分钟之间，且加上去必定落在刻度上', () {
      for (var m = 0; m <= 24 * 60; m++) {
        final truncated = (m / 60.0 * 100).truncateToDouble() / 100;
        final need = WorkTimeCalculator.minutesToNextBossStep(truncated);
        expect(need, inInclusiveRange(0, 5));
        expect((m + need) % WorkTimeCalculator.bossHoursStepMinutes, 0);
      }
    });
  });
}
