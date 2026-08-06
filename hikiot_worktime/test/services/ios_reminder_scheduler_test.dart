import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/ios_reminder_scheduler.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  // 固定为 UTC，避免测试结果随运行机器的时区漂移。
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
  });

  group('IosReminderScheduler.nextInstanceOf', () {
    test('当天该时间点尚未到达时返回今天', () {
      final result = IosReminderScheduler.nextInstanceOf(
        8,
        55,
        now: DateTime.utc(2026, 8, 4, 7, 30),
      );

      expect(result.year, 2026);
      expect(result.month, 8);
      expect(result.day, 4);
      expect(result.hour, 8);
      expect(result.minute, 55);
    });

    test('当天该时间点已过时顺延到明天', () {
      final result = IosReminderScheduler.nextInstanceOf(
        8,
        55,
        now: DateTime.utc(2026, 8, 4, 9, 0),
      );

      expect(result.day, 5);
      expect(result.hour, 8);
      expect(result.minute, 55);
    });

    test('正好等于当前时刻时顺延到明天，避免调度后立即触发', () {
      final result = IosReminderScheduler.nextInstanceOf(
        21,
        0,
        now: DateTime.utc(2026, 8, 4, 21, 0),
      );

      expect(result.day, 5);
      expect(result.hour, 21);
      expect(result.minute, 0);
    });

    test('跨月边界正确进位', () {
      final result = IosReminderScheduler.nextInstanceOf(
        8,
        55,
        now: DateTime.utc(2026, 8, 31, 23, 30),
      );

      expect(result.year, 2026);
      expect(result.month, 9);
      expect(result.day, 1);
    });

    test('跨年边界正确进位', () {
      final result = IosReminderScheduler.nextInstanceOf(
        8,
        55,
        now: DateTime.utc(2026, 12, 31, 23, 30),
      );

      expect(result.year, 2027);
      expect(result.month, 1);
      expect(result.day, 1);
    });
  });
}
