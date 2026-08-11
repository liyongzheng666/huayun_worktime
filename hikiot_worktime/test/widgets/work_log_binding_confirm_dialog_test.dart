import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/work_log_binding_confirm_dialog.dart';

const _csvName = '面向比亚迪公司的项目-自筹';
const _bossName = '面向比亚迪公司的项目-自筹(2)';

const _constants = {
  'projectId': 'PROJECT_aaa',
  'projectCode': 'PROJECT_bbb',
  'auditor': ';USERINFO_ccc',
  'projectName': _bossName,
  'auditorName': '张三',
};

/// 承接 show() 的返回值，供点完按钮后断言。
class Answer {
  bool? value;
}

Future<Answer> pumpDialog(
  WidgetTester tester, {
  Map<String, String> constants = _constants,
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogBindingConfirmDialog.show(
              context: context,
              csvProjectName: _csvName,
              constants: constants,
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
  group('项目绑定确认框', () {
    testWidgets('两个名字都要摆出来，用户才能看出差在哪', (tester) async {
      await pumpDialog(tester);

      expect(find.text(_csvName), findsOneWidget);
      expect(find.text(_bossName), findsOneWidget);
    });

    testWidgets('必须显示项目 ID', (tester) async {
      // 决定工时记到哪个项目的是 PROJECTID，不是名字；
      // 不给 ID 的话用户根本没有核对的依据
      await pumpDialog(tester);

      expect(find.text('PROJECT_aaa'), findsOneWidget);
    });

    testWidgets('说清这是自动选中的一条，可能不是要的那个', (tester) async {
      // 名字对不上意味着自动匹配没命中，只能退取一条记录。
      // 把它说成「BOSS 里就是这个项目」是在替用户下一个我们下不了的结论
      await pumpDialog(tester);

      expect(find.textContaining('没能在 BOSS 的历史日志里找到'), findsOneWidget);
      expect(find.textContaining('自动选中的一条'), findsOneWidget);
    });

    testWidgets('点「是同一个项目」返回 true', (tester) async {
      final answer = await pumpDialog(tester);
      await tester.tap(find.text('是同一个项目'));
      await tester.pumpAndSettle();

      expect(answer.value, isTrue);
    });

    testWidgets('点「不是同一个」返回 false', (tester) async {
      final answer = await pumpDialog(tester);
      await tester.tap(find.text('不是同一个'));
      await tester.pumpAndSettle();

      expect(answer.value, isFalse);
    });

    testWidgets('点框外不能糊弄过去', (tester) async {
      // 绑错项目的后果是工时记到别人名下，必须是一次明确的选择
      final answer = await pumpDialog(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('项目名对不上'), findsOneWidget);
      expect(answer.value, isNull);
    });

    testWidgets('审核人只有 ID 时明确说明，不显示空白', (tester) async {
      await pumpDialog(
        tester,
        constants: const {
          'projectId': 'PROJECT_aaa',
          'projectName': _bossName,
        },
      );

      expect(find.textContaining('未知，仅有 ID'), findsOneWidget);
    });
  });
}
