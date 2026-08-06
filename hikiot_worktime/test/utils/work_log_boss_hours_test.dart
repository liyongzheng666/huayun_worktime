import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_boss_hours.dart';

void main() {
  group('parseSingleDay', () {
    test('取出已填工时', () {
      expect(
        WorkLogBossHours.parseSingleDay('{"ok":true,"used":10.3}'),
        10.3,
      );
    });

    test('未填报返回 0 而不是 null', () {
      expect(WorkLogBossHours.parseSingleDay('{"ok":true,"used":0}'), 0);
    });

    test('查询失败返回 null，表示「未知」而非「未填报」', () {
      // 这个区分很重要：未知时提交确认框应提示用户自行核对，
      // 而不是让用户误以为当天确定没有日志。
      expect(WorkLogBossHours.parseSingleDay('{"ok":false}'), isNull);
      expect(WorkLogBossHours.parseSingleDay('不是JSON'), isNull);
      expect(WorkLogBossHours.parseSingleDay(null), isNull);
      expect(WorkLogBossHours.parseSingleDay(''), isNull);
    });
  });

  group('parseResult', () {
    test('解析整月工时表', () {
      final hours = WorkLogBossHours.parseResult(
        '{"ok":true,"hours":{"2026-08-05":10.3,"2026-08-06":8}}',
      );
      expect(hours.length, 2);
      expect(hours['2026-08-05'], 10.3);
      expect(hours['2026-08-06'], 8.0);
    });

    test('失败或非法输入返回空表而不是抛异常', () {
      expect(WorkLogBossHours.parseResult('{"ok":false}'), isEmpty);
      expect(WorkLogBossHours.parseResult('坏数据'), isEmpty);
      expect(WorkLogBossHours.parseResult(null), isEmpty);
    });
  });

  group('脚本约定', () {
    test('单日查询脚本不内嵌凭据，只复用抓包会话', () {
      final script = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      expect(script.contains('findPara'), isTrue);
      expect(script.contains('__store'), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('2026-08-05'), isTrue);
    });

    test('会话查找只依赖 UserID，登录后首页请求即可用', () {
      final script = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );
      expect(script.contains('UserID'), isTrue);
      expect(script.contains('ServiceUri'), isTrue); // 设置用，非筛选用
      expect(
        RegExp(r'p\.para\.UserID\)').hasMatch(script),
        isTrue,
        reason: '筛选条件应只有 UserID',
      );
    });

    test('整月脚本按月份天数循环，不写死 31 天', () {
      final script = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 2,
        captureStoreName: '__store',
      );
      expect(script.contains('new Date(YEAR, MONTH, 0).getDate()'), isTrue);
      expect(script.contains('var YEAR = 2026, MONTH = 2;'), isTrue);
    });
  });
}
