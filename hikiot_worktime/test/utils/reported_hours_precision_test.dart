import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/work_log_boss_hours.dart';
import 'package:hikiot_worktime/utils/work_time_calculator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('远端10.20经过真实解析和缓存后仍显示10.20', () async {
    final hours = WorkLogBossHours.parseSingleDay('{"ok":true,"used":"10.20"}');
    expect(hours, 10.2);
    final storage = StorageService();
    await storage.saveBossHoursForDate('2026-11-13', hours!);
    final saved = (await storage.loadBossHours('2026-11'))['2026-11-13']!;
    expect(saved, 10.2);
    expect(WorkTimeCalculator.formatHours(saved), '10.20');
  });

  test('输入10.20再格式化不能逐次丢失0.01小时', () {
    var text = '10.20';
    for (var i = 0; i < 20; i++) {
      final value = WorkTimeCalculator.parseHoursInput(text);
      expect(value, 10.2);
      text = WorkTimeCalculator.formatHours(value!);
      expect(text, '10.20');
    }
  });

  test('一天内所有两位小数工时可原样显示和手输往返', () {
    for (var cents = 1; cents <= 2400; cents++) {
      final text =
          '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
      final parsed = WorkTimeCalculator.parseHoursInput(text);
      expect(parsed, cents / 100, reason: '输入 $text');
      expect(
        WorkTimeCalculator.formatHours(cents / 100),
        text,
        reason: '显示 $text',
      );
    }
  });

  test('分钟转小时直接整数截断，全天每一分钟不多丢0.01', () {
    final start = WorkTimeCalculator.lunchStartMinutes;
    final end = WorkTimeCalculator.lunchEndMinutes;
    addTearDown(() {
      WorkTimeCalculator.lunchStartMinutes = start;
      WorkTimeCalculator.lunchEndMinutes = end;
    });
    WorkTimeCalculator.lunchStartMinutes = 0;
    WorkTimeCalculator.lunchEndMinutes = 0;
    for (var minutes = 0; minutes <= 1440; minutes++) {
      expect(
        WorkTimeCalculator.calculateWorkHours(0, minutes, deductLunch: false),
        (minutes * 100 ~/ 60) / 100,
        reason: '$minutes分钟',
      );
    }
    expect(
      WorkTimeCalculator.calculateWorkHours(0, 612, deductLunch: false),
      10.2,
    );
  });

  test('非法非有限输入和截断后零工时不允许提交', () {
    for (final value in ['NaN', 'Infinity', '-Infinity', '0.001']) {
      expect(WorkTimeCalculator.parseHoursInput(value), isNull);
    }
  });
}
