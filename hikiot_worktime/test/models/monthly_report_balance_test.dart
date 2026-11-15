import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';

void main() {
  MonthlyReportPlan plan(
    Map<String, int> actual, [
    Map<String, int> reported = const {},
  ]) => MonthlyReportBalance.calculate(
    actualByDate: actual,
    reportedByDate: reported,
  );

  int sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);

  test('用户样例三日合计不变，10.42/10.37/10.41均推荐10.40', () {
    final result = plan({
      '2026-11-01': 1042,
      '2026-11-02': 1037,
      '2026-11-03': 1041,
    });
    expect(result.actualTotal, 3120);
    expect(result.reportedTotal, 0);
    expect(result.remainingTotal, 3120);
    expect(result.remainder, 0);
    expect(result.suggestions, {
      '2026-11-01': 1040,
      '2026-11-02': 1040,
      '2026-11-03': 1040,
    });
    expect(result.problem, isNull);
    expect(result.isActionable, isTrue);
  });

  test('已填多报与少报均计入未填日期额度，保持已填日期不变', () {
    const actual = {
      '2026-11-01': 1000,
      '2026-11-02': 1042,
      '2026-11-03': 1037,
      '2026-11-04': 1041,
    };
    final over = plan(actual, {'2026-11-01': 1050});
    final under = plan(actual, {'2026-11-01': 950});
    expect(over.remainingTotal, 3070);
    expect(sum(over.suggestions.values), 3070);
    expect(under.remainingTotal, 3170);
    expect(sum(under.suggestions.values), 3170);
    expect(over.suggestions.keys, isNot(contains('2026-11-01')));
    expect(under.suggestions.keys, isNot(contains('2026-11-01')));
    expect(actual['2026-11-01'], 1000);
  });

  test('无法凑整的31.26只分配31.20并保留0.06尾差', () {
    final result = plan({'a': 1042, 'b': 1042, 'c': 1042});
    expect(sum(result.suggestions.values), 3120);
    expect(result.remainder, 6);
    expect(result.actualTotal, 3126);
  });

  test('已存在0工时日志仍视为已填，不重新给该日期生成建议', () {
    final result = plan({'a': 1000, 'b': 1000}, {'a': 0});
    expect(result.pendingActual, {'b': 1000});
    expect(result.suggestions, {'b': 2000});
  });

  test('已填超过整月实际总量时只报告负差额', () {
    final result = plan({'a': 1000, 'b': 1000}, {'a': 2100});
    expect(result.problem, MonthlyReportProblem.overReported);
    expect(result.remainingTotal, -100);
    expect(result.suggestions, isEmpty);
    expect(result.remainder, 0);
    expect(result.isActionable, isFalse);
  });

  test('没有未填日期且仍有差额时提示手工核对', () {
    final result = plan({'a': 1000}, {'a': 900});
    expect(result.problem, MonthlyReportProblem.noPendingDates);
    expect(result.remainingTotal, 100);
    expect(result.suggestions, isEmpty);
  });

  test('全部填完且没有差额，以及空月份，均无需手工调整', () {
    for (final result in [
      plan({'a': 1000}, {'a': 1000}),
      plan({}),
    ]) {
      expect(result.problem, isNull);
      expect(result.remainingTotal, 0);
      expect(result.suggestions, isEmpty);
      expect(result.isActionable, isFalse);
    }
  });

  test('没有实际工时的日期不成为候选，额度为0时不会产生负建议', () {
    expect(plan({'a': 0, 'b': 9}).suggestions, {'b': 0});
    final result = plan({'a': 1000, 'b': 1000}, {'a': 2000});
    expect(result.problem, isNull);
    expect(result.suggestions, {'b': 0});
    expect(result.remainingTotal, 0);
  });

  test('补差超过未填日期每天24小时容量时不给截短的假建议', () {
    final result = plan({'a': 2000, 'b': 1000}, {'a': 0});
    expect(result.problem, MonthlyReportProblem.capacityExceeded);
    expect(result.remainingTotal, 3000);
    expect(result.suggestions, isEmpty);
  });

  test('允许24小时边界以及不足0.1的尾差', () {
    final result = plan({'a': 2409});
    expect(result.problem, isNull);
    expect(result.suggestions, {'a': 2400});
    expect(result.remainder, 9);
  });

  test('报告中出现考勤表以外的已填日期也要扣入总量', () {
    final result = plan({'a': 1000, 'b': 1000}, {'other': 500});
    expect(result.remainingTotal, 1500);
    expect(sum(result.suggestions.values), 1500);
  });

  test('相同输入乱序仍给出稳定方案，等价增量优先日期较早的一天', () {
    final first = plan({'b': 1005, 'a': 1005});
    final second = plan({'a': 1005, 'b': 1005});
    expect(first.suggestions, {'a': 1010, 'b': 1000});
    expect(second.suggestions, first.suggestions);
    expect(first.suggestions.keys.toList(), ['a', 'b']);
  });

  test('计算结果不可修改，输入修改不会反向影响已生成方案', () {
    final actual = {'a': 1000};
    final result = plan(actual);
    actual['a'] = 2000;
    expect(result.pendingActual, {'a': 1000});
    expect(() => result.pendingActual['a'] = 10, throwsUnsupportedError);
    expect(() => result.suggestions.clear(), throwsUnsupportedError);
  });

  test('负数工时与空日期为无效输入', () {
    expect(() => plan({'a': -1}), throwsArgumentError);
    expect(() => plan({'a': 1}, {'a': -1}), throwsArgumentError);
    expect(() => plan({'': 1}), throwsArgumentError);
  });

  test('整数格式化固定两位，正确处理正负0.01和整小时', () {
    const cases = {
      0: '0.00',
      1: '0.01',
      -1: '-0.01',
      50: '0.50',
      -50: '-0.50',
      100: '1.00',
      -100: '-1.00',
      1040: '10.40',
      3126: '31.26',
    };
    for (final entry in cases.entries) {
      expect(MonthlyReportBalance.formatHundredths(entry.key), entry.value);
    }
  });

  test('小范围穷举验证分配方案确实最小化每日平方偏差', () {
    final random = Random(20261115);
    for (var trial = 0; trial < 100; trial++) {
      final a = random.nextInt(400) + 1;
      final b = random.nextInt(400) + 1;
      final reported = random.nextInt(a + b + 1);
      final result = plan({'a': a, 'b': b}, {'filed': reported});
      expect(result.problem, isNull);
      final units = result.remainingTotal ~/ 10;
      var best = 1 << 60;
      for (var aUnits = 0; aUnits <= units; aUnits++) {
        final da = aUnits * 10 - a;
        final db = (units - aUnits) * 10 - b;
        best = min(best, da * da + db * db);
      }
      final da = result.suggestions['a']! - a;
      final db = result.suggestions['b']! - b;
      expect(da * da + db * db, best, reason: 'trial $trial');
    }
  });

  test('随机整月输入保持总量、步长、容量、尾差和输入不变', () {
    final random = Random(20261116);
    for (var trial = 0; trial < 120; trial++) {
      final days = random.nextInt(31) + 1;
      final actual = <String, int>{};
      final reported = <String, int>{};
      for (var day = 1; day <= days; day++) {
        final date = '2026-11-${day.toString().padLeft(2, '0')}';
        actual[date] = random.nextInt(2401);
        if (random.nextBool()) reported[date] = random.nextInt(2401);
      }
      final originalActual = Map.of(actual);
      final originalReported = Map.of(reported);
      final result = plan(actual, reported);
      expect(result.actualTotal, sum(actual.values));
      expect(result.reportedTotal, sum(reported.values));
      expect(result.remainingTotal, result.actualTotal - result.reportedTotal);
      expect(actual, originalActual);
      expect(reported, originalReported);
      if (result.problem != null) {
        expect(result.suggestions, isEmpty);
        continue;
      }
      expect(result.remainder, inInclusiveRange(0, 9));
      expect(
        sum(result.suggestions.values) + result.remainder,
        result.remainingTotal,
      );
      for (final entry in result.suggestions.entries) {
        expect(reported.containsKey(entry.key), isFalse);
        expect(actual[entry.key], greaterThan(0));
        expect(entry.value, inInclusiveRange(0, 2400));
        expect(entry.value % 10, 0);
      }
    }
  });
}
