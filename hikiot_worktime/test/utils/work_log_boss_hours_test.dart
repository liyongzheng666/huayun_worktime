import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_session_script.dart';
import 'package:hikiot_worktime/utils/work_log_boss_hours.dart';

void main() {
  group('parseSingleDay', () {
    test('取出已填工时', () {
      expect(WorkLogBossHours.parseSingleDay('{"ok":true,"used":10.3}'), 10.3);
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

    test('自动刷新解析能区分查询失败与成功的空月份', () {
      expect(
        WorkLogBossHours.parseSuccessfulResult('{"ok":true,"hours":{}}'),
        isEmpty,
      );
      expect(
        WorkLogBossHours.parseSuccessfulResult('{"ok":false,"hours":{}}'),
        isNull,
      );
      expect(WorkLogBossHours.parseSuccessfulResult('坏数据'), isNull);
    });
  });

  group('脚本约定', () {
    test('单日查询脚本不内嵌凭据，只复用抓包会话', () {
      final script = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      expect(script.contains('bossFindPara()'), isTrue);
      expect(script.contains('__store'), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('2026-08-05'), isTrue);
    });

    test('整月脚本与单日脚本共用同一套会话查找', () {
      // 历史教训：整月脚本曾经把 ServiceUri 也加进筛选条件，而单日脚本没有，
      // 表现为刚登录时同步整月报「未捕获到会话」、单日查询却正常，
      // 现象自相矛盾且极难排查（踩坑记录 3.11）。两者必须走同一份实现。
      final month = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 8,
        captureStoreName: '__store',
      );
      final single = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      final preamble = BossSessionScript.sessionPreamble(
        captureStoreName: '__store',
      );
      expect(month.contains(preamble), isTrue);
      expect(single.contains(preamble), isTrue);
    });

    test('单日与整月都用同一个「取已填工时」的解析，避免取错列', () {
      // 返回值是 [总额度, 已填, 剩余]，取错一位就会把额度当成已填
      final month = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 8,
        captureStoreName: '__store',
      );
      final single = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      expect(month.contains('function pickUsed(data)'), isTrue);
      expect(single.contains('function pickUsed(data)'), isTrue);
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
