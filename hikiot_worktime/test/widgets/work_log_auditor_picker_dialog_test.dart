import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_auditor_lookup.dart';
import 'package:hikiot_worktime/widgets/work_log_auditor_picker_dialog.dart';

const _fromSetting = BossAuditor(
  id: ';USERINFO_setting',
  name: '张三',
  source: BossAuditorSource.setting,
);
const _fromService = BossAuditor(
  id: ';USERINFO_service',
  name: '项目审核人',
  source: BossAuditorSource.service,
);
const _fromField = BossAuditor(id: ';USERINFO_field', name: '李四');
const _noName = BossAuditor(id: ';USERINFO_noname');

class Answer {
  AuditorPickResult? value;
}

Future<Answer> pumpDialog(
  WidgetTester tester, {
  List<BossAuditor> auditors = const [],
  String currentId = '',
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogAuditorPickerDialog.show(
              context: context,
              auditors: auditors,
              currentId: currentId,
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
  group('有候选时', () {
    testWidgets('列出候选并提示核对当前项目的审核人', (tester) async {
      await pumpDialog(tester, auditors: const [_fromSetting, _fromField]);

      expect(find.textContaining('查到 2 个候选'), findsOneWidget);
      expect(find.textContaining('确认当前项目的审核人'), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('李四'), findsOneWidget);
    });

    testWidgets('每条都标出来源，而不是打分', (tester) async {
      await pumpDialog(tester, auditors: const [_fromSetting, _fromField]);

      expect(find.text('你的默认审核人设置'), findsOneWidget);
      expect(find.text('出现在日志的审核人字段里'), findsOneWidget);
    });

    testWidgets('没扫到姓名的照直说，不显示成空白', (tester) async {
      // 空白会让人以为是渲染问题，而这里的空白意味着没法肉眼核对
      await pumpDialog(tester, auditors: const [_noName]);

      expect(find.text('（没扫到姓名）'), findsOneWidget);
    });

    testWidgets('默认选中个人设置那条', (tester) async {
      await pumpDialog(tester, auditors: const [_fromSetting, _fromField]);

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    });

    testWidgets('当前项目接口的唯一候选优先于个人设置', (tester) async {
      final answer = await pumpDialog(
        tester,
        auditors: const [_fromSetting, _fromService],
      );

      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value!.auditor?.id, _fromService.id);
    });

    testWidgets('当前项目有多个审核人时不预选个人设置', (tester) async {
      await pumpDialog(
        tester,
        auditors: const [
          _fromSetting,
          _fromService,
          BossAuditor(
            id: ';USERINFO_service2',
            name: '另一项目审核人',
            source: BossAuditorSource.service,
          ),
        ],
      );

      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '就用选中的'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('已确认的审核人不被当前项目默认候选替换', (tester) async {
      final answer = await pumpDialog(
        tester,
        auditors: const [_fromField, _fromService],
        currentId: _fromField.id,
      );

      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value!.auditor?.id, _fromField.id);
    });

    testWidgets('全是普通字段来源时一个都不预选', (tester) async {
      // 排序靠前不代表就是审核人；预选就是一次默认同意
      await pumpDialog(tester, auditors: const [_fromField, _noName]);

      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    });

    testWidgets('只有一位历史字段候选也不自动预选', (tester) async {
      await pumpDialog(tester, auditors: const [_fromField]);

      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '就用选中的'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('一个都没选时不许确定', (tester) async {
      final answer = await pumpDialog(
        tester,
        auditors: const [_fromField, _noName],
      );

      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value, isNull);
      expect(find.text('选择日志审核人'), findsOneWidget);
    });

    testWidgets('选中后回传该审核人', (tester) async {
      final answer = await pumpDialog(
        tester,
        auditors: const [_fromSetting, _fromField],
      );

      await tester.tap(find.text('李四'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isTrue);
      expect(answer.value!.auditor?.id, ';USERINFO_field');
    });

    testWidgets('标出当前在用的那个', (tester) async {
      await pumpDialog(
        tester,
        auditors: const [_fromSetting, _fromField],
        currentId: ';USERINFO_field',
      );

      expect(find.text('当前用的就是他'), findsOneWidget);
    });

    testWidgets('必须说明选错的后果', (tester) async {
      await pumpDialog(tester, auditors: const [_fromSetting]);

      expect(find.textContaining('错误的审批人'), findsOneWidget);
    });

    testWidgets('「都不是」返回未确认', (tester) async {
      final answer = await pumpDialog(tester, auditors: const [_fromSetting]);

      await tester.tap(find.text('都不是'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isFalse);
    });
  });

  group('一个候选都没有时', () {
    testWidgets('给出该怎么办，而不是只说没有', (tester) async {
      await pumpDialog(tester);

      expect(find.textContaining('没能查到当前项目的审核人'), findsOneWidget);
      expect(find.textContaining('这个项目的历史日志'), findsOneWidget);
      expect(find.textContaining('手工填审核人 ID'), findsOneWidget);
    });

    testWidgets('没得选就不给「就用选中的」这个按钮', (tester) async {
      await pumpDialog(tester);

      expect(find.text('就用选中的'), findsNothing);
      expect(find.text('知道了'), findsOneWidget);
    });
  });

  testWidgets('点框外不能糊弄过去', (tester) async {
    // 发给错误的审批人不是能糊弄过去的事
    final answer = await pumpDialog(tester, auditors: const [_fromSetting]);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('选择日志审核人'), findsOneWidget);
    expect(answer.value, isNull);
  });
}
