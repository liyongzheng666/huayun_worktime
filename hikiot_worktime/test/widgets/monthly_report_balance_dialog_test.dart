import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/monthly_report_balance.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/widgets/monthly_report_balance_dialog.dart';

const _actual = {'2026-11-01': 1042, '2026-11-02': 1037, '2026-11-03': 1041};

MonthlyReportSnapshot _snapshot({
  Map<String, int> actual = _actual,
  Map<String, int> reported = const {},
  String? unavailableReason,
  bool monthEnd = false,
}) => MonthlyReportSnapshot(
  month: DateTime(2026, 11),
  asOf: DateTime(2026, 11, monthEnd ? 30 : 10),
  lastWorkday: DateTime(2026, 11, 30),
  plan: MonthlyReportBalance.calculate(
    actualByDate: actual,
    reportedByDate: reported,
  ),
  unavailableReason: unavailableReason,
  bossRevision: 0,
  fingerprint: 'test-snapshot',
);

class _Answer {
  int? value;
  bool returned = false;
}

Future<_Answer> _open(
  WidgetTester tester,
  MonthlyReportSnapshot snapshot, {
  String? selectedDate,
  double textScale = 1,
}) async {
  final answer = _Answer();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              answer.value = await MonthlyReportBalanceDialog.show(
                context: context,
                snapshot: snapshot,
                selectedDate: selectedDate,
              );
              answer.returned = true;
            },
            child: const Text('查看'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('查看'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('预览完整合计及未填日建议，关闭不采用且没有提交操作', (tester) async {
    final answer = await _open(tester, _snapshot());

    expect(find.text('月度填报工时建议'), findsOneWidget);
    expect(find.text('实际工作总工时'), findsOneWidget);
    expect(find.text('已填报总工时'), findsOneWidget);
    expect(find.text('未填日期可分配工时'), findsOneWidget);
    expect(find.text('本次建议合计'), findsOneWidget);
    expect(find.text('31.20 小时'), findsNWidgets(3));
    expect(find.text('建议 10.40'), findsNWidgets(3));
    expect(find.text('原工时 10.37'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('确认提交'), findsNothing);
    expect(answer.returned, isFalse);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(answer.returned, isTrue);
    expect(answer.value, isNull);
  });

  testWidgets('明确采用当前日期时返回整数建议，供原确认流程继续核对', (tester) async {
    final answer = await _open(tester, _snapshot(), selectedDate: '2026-11-02');
    expect(find.text('当前日期 · 2026-11-02'), findsOneWidget);
    expect(answer.returned, isFalse);

    await tester.tap(find.text('采用 2026-11-02 建议'));
    await tester.pumpAndSettle();
    expect(answer.returned, isTrue);
    expect(answer.value, 1040);
  });

  testWidgets('数据未确认时展示原因，即使有旧计划也不能采用', (tester) async {
    await _open(
      tester,
      _snapshot(unavailableReason: '华天工时已过期，请先同步本月数据'),
      selectedDate: '2026-11-02',
    );
    expect(find.text('华天工时已过期，请先同步本月数据'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('本次建议合计'), findsNothing);
  });

  testWidgets('多报已超过实际总量时显示负差额并提示手动编辑已有日报', (tester) async {
    await _open(
      tester,
      _snapshot(
        actual: const {'2026-11-01': 1000, '2026-11-02': 1000},
        reported: const {'2026-11-01': 2100},
      ),
      selectedDate: '2026-11-02',
    );
    expect(find.text('-1.00 小时'), findsOneWidget);
    expect(find.textContaining('未填日期无法继续抵扣'), findsOneWidget);
    expect(find.textContaining('手动编辑已填日报'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('没有未填日期但仍有差额时提示核对已有日报', (tester) async {
    await _open(
      tester,
      _snapshot(
        actual: const {'2026-11-01': 1000},
        reported: const {'2026-11-01': 950},
      ),
    );
    expect(find.textContaining('已没有可分配的未填日期'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('已填日期没有采用入口，差额只进入其他未填日期', (tester) async {
    await _open(
      tester,
      _snapshot(
        actual: const {'2026-11-01': 1000, '2026-11-02': 1000},
        reported: const {'2026-11-01': 950},
      ),
      selectedDate: '2026-11-01',
    );
    expect(find.text('建议 10.50'), findsOneWidget);
    expect(find.textContaining('所选日期不在本次待填建议中'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('补差超出日容量时提示手动核对，不提供超额采用入口', (tester) async {
    await _open(
      tester,
      _snapshot(
        actual: const {'2026-11-01': 2400, '2026-11-02': 2000},
        reported: const {'2026-11-01': 0},
      ),
      selectedDate: '2026-11-02',
    );
    expect(find.textContaining('超出未填日期的可分配范围'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('零建议保留在预览中并提示无需提交零工时日志', (tester) async {
    await _open(
      tester,
      _snapshot(
        actual: const {'2026-11-01': 100, '2026-11-02': 100},
        reported: const {'2026-11-01': 200},
      ),
      selectedDate: '2026-11-02',
    );
    expect(find.text('建议 0.00'), findsOneWidget);
    expect(find.textContaining('无需提交零工时日志'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('月底前保留尾差，月底预览提示最终舍弃不足步长部分', (tester) async {
    const actual = {'2026-11-01': 1042, '2026-11-02': 1037, '2026-11-03': 1047};
    await _open(tester, _snapshot(actual: actual));
    expect(find.textContaining('尾差 0.06 小时先保留'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await _open(tester, _snapshot(actual: actual, monthEnd: true));
    expect(find.textContaining('尾差 0.06 小时不足 0.10 小时'), findsOneWidget);
    expect(find.textContaining('建议最终舍弃'), findsOneWidget);
  });

  testWidgets('窄屏大字支持滚动至月末日期且保留采用操作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final answer = await _open(
      tester,
      _snapshot(
        actual: {
          for (var day = 1; day <= 30; day++)
            '2026-11-${day.toString().padLeft(2, '0')}': 1000,
        },
      ),
      selectedDate: '2026-11-30',
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    final scrollable = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('monthly-balance-2026-11-30')),
      250,
      scrollable: scrollable.first,
    );
    expect(find.text('当前日期 · 2026-11-30'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('采用 2026-11-30 建议'));
    await tester.pumpAndSettle();
    expect(answer.value, 1000);
    expect(tester.takeException(), isNull);
  });
}
