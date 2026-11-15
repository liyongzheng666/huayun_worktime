import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/widgets/work_log_confirm_dialog.dart';

import '../helpers/monthly_report_balance_fixture.dart';

const _entry = WorkLogEntry(
  date: '2026-09-01',
  projectName: '测试',
  workType: '研发',
  stage: '无',
  activity: '无',
  title: '测试日志',
  content: '测试内容',
);

class _GatedBalance extends MonthlyReportBalanceService {
  _GatedBalance(MonthlyBalanceFixture fixture)
    : super(storage: fixture.storage, clock: () => fixture.now);
  final gate = Completer<void>();

  @override
  Future<bool> isCurrent(MonthlyReportSnapshot snapshot) async {
    await gate.future;
    return super.isCurrent(snapshot);
  }
}

class _ConfirmGateBalance extends MonthlyReportBalanceService {
  _ConfirmGateBalance(MonthlyBalanceFixture fixture)
    : super(storage: fixture.storage, clock: () => fixture.now);
  Completer<void>? gate;

  @override
  Future<bool> isCurrent(MonthlyReportSnapshot snapshot) async {
    await gate?.future;
    return super.isCurrent(snapshot);
  }
}

void main() {
  late MonthlyBalanceFixture fixture;
  WorkLogConfirmOutcome? answer;

  setUp(() async {
    fixture = MonthlyBalanceFixture();
    await fixture.seed();
    answer = null;
  });

  Future<void> open(
    WidgetTester tester, {
    double hours = 10.42,
    String date = '2026-09-01',
    MonthlyReportBalanceService? service,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              answer = await WorkLogConfirmDialog.show(
                context: context,
                date: date,
                entry: _entry,
                hours: WorkLogHours(
                  hours: hours,
                  checkIn: '08:00',
                  checkOut: '19:00',
                ),
                existingHours: 0,
                constants: const {'auditorName': '测试'},
                balanceService: service ?? fixture.service,
                now: fixture.now,
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.ensureVisible(find.text('整月工时建议'));
    await tester.tap(find.text('整月工时建议'));
    await tester.pumpAndSettle();
    expect(find.text('月度填报工时建议'), findsOneWidget);
  }

  Future<void> adopt(WidgetTester tester, {String date = '2026-09-01'}) async {
    await preview(tester);
    await tester.tap(find.text('采用 $date 建议'));
    await tester.pumpAndSettle();
  }

  testWidgets('真实月度数据预览并采用10.40后仍需确认才返回，原始数据不变', (tester) async {
    await open(tester);
    await adopt(tester);
    expect(answer, isNull);
    expect(find.textContaining('再待'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '10.40',
    );
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '10.40');
    expect(answer!.monthlyBalance!.plan!.actualTotal, 3120);
    expect(
      (await fixture.storage.loadMonthlyData(
        'test-team',
        '2026-09',
      ))!['2026-09-01']!['hours'],
      10.42,
    );
    expect(await fixture.storage.loadBossHours('2026-09'), isEmpty);
  });

  testWidgets('填报确认直接显示本日建议，可原地采用再确认，无需打开整月列表', (tester) async {
    await open(tester);
    expect(find.text('本日建议填报 10.40 小时'), findsOneWidget);
    expect(find.text('月度填报工时建议'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '10.42',
    );
    await tester.ensureVisible(find.text('采用本日建议'));
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    expect(answer, isNull);
    expect(find.text('已采用本日建议'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '10.40',
    );
    expect(find.textContaining('再待'), findsNothing);
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '10.40');
    expect(answer!.monthlyBalance, isNotNull);
  });

  testWidgets('原地采用尚在校验时禁用输入与确认，避免原值抢先提交或迟到覆盖', (tester) async {
    final service = _GatedBalance(fixture);
    await open(tester, service: service);
    final oldConfirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认提交'))
        .onPressed!;
    await tester.ensureVisible(find.text('采用本日建议'));
    await tester.tap(find.text('采用本日建议'));
    // 模拟按钮尚未重建时同帧到达的第二次点击。
    oldConfirm();
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认提交'))
          .onPressed,
      isNull,
    );
    expect(answer, isNull);
    service.gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '10.40',
    );
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '10.40');
  });

  testWidgets('关闭预览保留原工时，未采用不会改变提交值', (tester) async {
    await open(tester);
    await preview(tester);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '10.42');
    expect(answer!.monthlyBalance, isNull);
  });

  testWidgets('采用后手工修改尊重用户输入并取消月度建议绑定', (tester) async {
    await open(tester);
    await adopt(tester);
    await tester.enterText(find.byType(TextField), '10.50');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '10.50');
    expect(answer!.monthlyBalance, isNull);
  });

  testWidgets('最终校验期间再次改动工时，不能按旧输入结束确认', (tester) async {
    final service = _ConfirmGateBalance(fixture);
    await open(tester, service: service);
    await tester.ensureVisible(find.text('采用本日建议'));
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    service.gate = Completer<void>();
    await tester.tap(find.text('确认提交'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '9.00');
    await tester.pump();
    service.gate!.complete();
    await tester.pumpAndSettle();
    expect(answer, isNull);
    expect(find.textContaining('工时已变化，请重新确认'), findsOneWidget);
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '9.00');
    expect(answer!.monthlyBalance, isNull);
  });

  testWidgets('最终校验期间取消，迟到结果不能再次关闭页面或使用已销毁输入框', (tester) async {
    final service = _ConfirmGateBalance(fixture);
    await open(tester, service: service);
    await tester.ensureVisible(find.text('采用本日建议'));
    await tester.tap(find.text('采用本日建议'));
    await tester.pumpAndSettle();
    service.gate = Completer<void>();
    await tester.tap(find.text('确认提交'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await fixture.storage.saveBossHoursForDate(
      '2026-09-02',
      10.5,
      refreshedAt: fixture.now,
    );
    service.gate!.complete();
    await tester.pumpAndSettle();
    expect(answer, isNull);
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认期间其它日期已填发生变化，阻止旧建议返回', (tester) async {
    await open(tester);
    await adopt(tester);
    await fixture.storage.saveBossHoursForDate(
      '2026-09-02',
      10.5,
      refreshedAt: fixture.now,
    );
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer, isNull);
    expect(find.textContaining('月度数据已变化'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('4.10建议保持整数格式，不被浮点输入解析变成4.09', (tester) async {
    await fixture.seed(hours: const [4.12, 4.08]);
    await open(tester, hours: 4.12);
    await adopt(tester);
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.actWork, '4.10');
  });

  testWidgets('采用后切换当前时间来源清除月度建议绑定', (tester) async {
    await open(tester, hours: 10.41, date: '2026-09-03');
    await adopt(tester, date: '2026-09-03');
    final source = find.textContaining('当前时间 ');
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer!.monthlyBalance, isNull);
    expect(answer!.actWork, '10.00');
  });
}
