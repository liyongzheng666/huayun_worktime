import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/target_progress_helper.dart';

void main() {
  group('目标列表范围', () {
    test('从最低目标排到基础目标，基础目标是最后一项', () {
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 8,
        baseTarget: 160,
        minTarget: 120,
        pinnedTarget: null,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [
        120,
        130,
        140,
        150,
        160,
      ]);
    });

    test('低于最低目标的挡位不再出现', () {
      // 100%、110% 常年满足，列在最前面只会挤占版面
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 8,
        baseTarget: 160,
        minTarget: 120,
        pinnedTarget: null,
      );

      final targets = result.sortedTargetData.map((d) => d['target']).toList();
      expect(targets, isNot(contains(100)));
      expect(targets, isNot(contains(110)));
    });

    test('最低目标可下调，调低后低挡位重新出现', () {
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 8,
        baseTarget: 130,
        minTarget: 100,
        pinnedTarget: null,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [
        100,
        110,
        120,
        130,
      ]);
    });

    test('最低目标等于基础目标时只有一项', () {
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 8,
        baseTarget: 120,
        minTarget: 120,
        pinnedTarget: null,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [120]);
    });

    test('最低目标被设得比基础目标还高时，至少保留基础目标', () {
      // 设置被改乱的情况。返回空列表会让整个进度区凭空消失，更难排查。
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 8,
        baseTarget: 120,
        minTarget: 150,
        pinnedTarget: null,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [120]);
    });

    test('超过基础目标后补上更高挡位，且都排在基础目标之后', () {
      // 冲过头之后总得有可追的目标，但不能打乱「基础目标是配置范围内最后一项」
      final result = TargetProgressHelper.buildDailyProgress(
        displayHours: 12.8, // 160%
        baseTarget: 140,
        minTarget: 120,
        pinnedTarget: null,
      );

      final targets = result.sortedTargetData
          .map((d) => d['target'] as int)
          .toList();
      expect(targets.take(3).toList(), [120, 130, 140]);
      expect(targets.every((t) => t >= 120), isTrue);
      expect(targets, contains(300));
    });
  });

  group('排序与置顶', () {
    test('严格按目标从小到大排列', () {
      final result = TargetProgressHelper.buildMonthlyProgress(
        adjustedTotalHours: 80,
        baseHours: 80,
        avgHoursPerDay: 9,
        remainingWorkDays: 5,
        baseTarget: 160,
        minTarget: 120,
        pinnedTarget: null,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [
        120,
        130,
        140,
        150,
        160,
      ]);
    });

    test('仍然标出最高达成与下一个目标，但不再改变顺序', () {
      // 智能排序已移除，这两个值只用于卡片上的徽章与配色，
      // 列表顺序恒为升序。
      final result = TargetProgressHelper.buildMonthlyProgress(
        // 总量仅到 100%（尚未达成任何目标），但日均已够 130%
        adjustedTotalHours: 80,
        baseHours: 80,
        avgHoursPerDay: 10.4,
        remainingWorkDays: 5,
        baseTarget: 160,
        minTarget: 120,
        pinnedTarget: null,
      );

      expect(result.highestAchievedTarget, 130);
      expect(result.nextToAchieveTarget, 140);
      expect(result.sortedTargetData.map((d) => d['target']).toList(), [
        120,
        130,
        140,
        150,
        160,
      ]);
    });

    test('置顶目标排到最前，其余仍为升序', () {
      final result = TargetProgressHelper.buildMonthlyProgress(
        adjustedTotalHours: 80,
        baseHours: 80,
        avgHoursPerDay: 10.4,
        remainingWorkDays: 5,
        baseTarget: 160,
        minTarget: 120,
        pinnedTarget: 150,
      );

      expect(result.sortedTargetData.map((d) => d['target']).toList(), [
        150,
        120,
        130,
        140,
        160,
      ]);
      expect(result.highestAchievedTarget, 130);
      expect(result.nextToAchieveTarget, 140);
    });
  });
}
