import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_edit_script.dart';
import 'package:hikiot_worktime/widgets/work_log_edit_dialog.dart';

const record = BossWorkLogRecord(
  objectId: 'WORKLOG_123',
  rawData: {
    'EID': 'WORKLOG_123',
    'ENAME': '原标题',
    'LOGCONTENT': '原内容',
    'ACTWORK': '8.0',
    'LOGDATE_DisplayValue': '2026-09-03',
    'PROJECTID_DisplayValue': '项目一',
  },
);

class Answer {
  WorkLogEditOutcome? value;
}

Future<Answer> pumpDialog(WidgetTester tester) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogEditDialog.show(
              context: context,
              record: record,
            );
          },
          child: const Text('打开'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('显示服务端原记录，不拿 CSV 草稿冒充已提交内容', (tester) async {
    await pumpDialog(tester);

    expect(find.text('编辑 2026-09-03'), findsOneWidget);
    expect(find.widgetWithText(TextField, '原标题'), findsOneWidget);
    expect(find.widgetWithText(TextField, '原内容'), findsOneWidget);
    expect(find.widgetWithText(TextField, '8.00'), findsOneWidget);
    expect(find.text('项目一'), findsOneWidget);
  });

  testWidgets('内容没有变化时不允许空保存', (tester) async {
    await pumpDialog(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存修改'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('修改时长后返回截断两位的更新值', (tester) async {
    final answer = await pumpDialog(tester);
    await tester.enterText(find.widgetWithText(TextField, '8.00'), '9.567');
    await tester.pump();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(answer.value?.title, '原标题');
    expect(answer.value?.content, '原内容');
    expect(answer.value?.actWork, '9.56');
  });

  testWidgets('标题、内容为空或工时非法时不允许保存', (tester) async {
    await pumpDialog(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '');
    await tester.enterText(fields.at(1), '');
    await tester.enterText(fields.at(2), '99');
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存修改'),
    );
    expect(button.onPressed, isNull);
  });
}
