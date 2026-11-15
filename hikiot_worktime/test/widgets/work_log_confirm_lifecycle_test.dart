import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/widgets/work_log_confirm_dialog.dart';
import '../helpers/monthly_report_balance_fixture.dart';

void main() {
  for (final action in ['取消', '确认提交']) {
    testWidgets('反复输入后$action，输入控制器保持到弹窗反向动画结束', (tester) async {
      final fixture = MonthlyBalanceFixture();
      await fixture.seed();
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      WorkLogConfirmOutcome? outcome;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                outcome = await WorkLogConfirmDialog.show(
                  context: context,
                  date: '2026-09-03',
                  entry: const WorkLogEntry(
                    date: '2026-09-03',
                    projectName: '测试',
                    workType: '研发',
                    stage: '无',
                    activity: '无',
                    title: '测试',
                    content: '测试',
                  ),
                  hours: const WorkLogHours(
                    hours: 10.41,
                    checkIn: '08:00',
                    checkOut: '19:00',
                  ),
                  existingHours: 0,
                  constants: const {'projectName': '测试', 'auditorName': '测试'},
                  balanceService: fixture.service,
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
      for (var i = 0; i < 130; i++) {
        await tester.enterText(
          find.byType(TextField),
          i == 129 ? '10.20' : ['10.42', '9.50', '8.37'][i % 3],
        );
        await tester.pump();
      }
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('打开'), findsOneWidget);
      expect(outcome?.actWork, action == '取消' ? isNull : '10.20');
    });
  }
}
