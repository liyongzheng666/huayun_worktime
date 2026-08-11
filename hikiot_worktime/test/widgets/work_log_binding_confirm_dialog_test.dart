import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';
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

const _projects = [
  BossProject(id: 'PROJECT_aaa', name: _bossName),
  BossProject(id: 'PROJECT_zzz', name: '运维平台三期'),
];

/// 承接 show() 的返回值，供点完按钮后断言。
class Answer {
  BindingChoice? value;
}

Future<Answer> pumpDialog(
  WidgetTester tester, {
  Map<String, String> constants = _constants,
  List<BossProject> projects = const [],
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
              projects: projects,
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
  group('扫不到项目清单时（退回单项确认）', () {
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
      await pumpDialog(tester);

      expect(find.textContaining('没能在 BOSS 的历史日志里找到'), findsOneWidget);
      expect(find.textContaining('自动选中的一条'), findsOneWidget);
    });

    testWidgets('点「是同一个项目」返回确认，且不带改选', (tester) async {
      final answer = await pumpDialog(tester);
      await tester.tap(find.text('是同一个项目'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isTrue);
      expect(answer.value!.project, isNull);
    });

    testWidgets('点「不是同一个」返回未确认', (tester) async {
      final answer = await pumpDialog(tester);
      await tester.tap(find.text('不是同一个'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isFalse);
    });
  });

  group('扫到项目清单时（候选列表）', () {
    testWidgets('列出所有候选并报出数量', (tester) async {
      await pumpDialog(tester, projects: _projects);

      expect(find.textContaining('扫到 2 个项目'), findsOneWidget);
      expect(find.text(_bossName), findsOneWidget);
      expect(find.text('运维平台三期'), findsOneWidget);
    });

    testWidgets('每个候选都标出匹配档位，而不是打分', (tester) async {
      // 分数会被读成「有多大把握」，而是不是同一个项目只有用户知道
      await pumpDialog(tester, projects: _projects);

      expect(find.text('名称包含关系，可能是同一项目'), findsOneWidget);
      expect(find.text('名称差别较大'), findsOneWidget);
    });

    testWidgets('默认选中自动学到的那个，并标明它含审核人配置', (tester) async {
      await pumpDialog(tester, projects: _projects);

      expect(
        find.textContaining('当前自动学到的就是它'),
        findsOneWidget,
      );
      // 默认选中它，因此不该出现「你选的不是自动学到的那个」的警告
      expect(find.textContaining('你选的不是自动学到的'), findsNothing);
    });

    testWidgets('改选别的项目会回传该项目', (tester) async {
      final answer = await pumpDialog(tester, projects: _projects);

      await tester.tap(find.text('运维平台三期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isTrue);
      expect(answer.value!.project?.id, 'PROJECT_zzz');
    });

    testWidgets('改选后必须提示审核人仍是旧的', (tester) async {
      // 审核人填错会把日志提交给错误的审批人，不能默默沿用
      await pumpDialog(tester, projects: _projects);

      await tester.tap(find.text('运维平台三期'));
      await tester.pumpAndSettle();

      expect(find.textContaining('审核人仍沿用当前学到的'), findsOneWidget);
      expect(find.textContaining('张三'), findsOneWidget);
    });

    testWidgets('选中的就是自动学到的那个时不回传，避免覆盖完整配置', (tester) async {
      // 回传一份只有 id/name 的项目会把审核人和项目编码冲掉
      final answer = await pumpDialog(tester, projects: _projects);

      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isTrue);
      expect(answer.value!.project, isNull);
    });

    testWidgets('「都不是」仍然可用', (tester) async {
      final answer = await pumpDialog(tester, projects: _projects);
      await tester.tap(find.text('都不是'));
      await tester.pumpAndSettle();

      expect(answer.value!.confirmed, isFalse);
    });
  });

  testWidgets('点框外不能糊弄过去', (tester) async {
    // 绑错项目的后果是工时记到别人名下，必须是一次明确的选择
    final answer = await pumpDialog(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('项目名对不上'), findsOneWidget);
    expect(answer.value, isNull);
  });
}
