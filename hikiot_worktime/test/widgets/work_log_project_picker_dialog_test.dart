import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';
import 'package:hikiot_worktime/widgets/work_log_project_picker_dialog.dart';

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
  ProjectPickResult? value;
}

Future<Answer> pumpDialog(
  WidgetTester tester, {
  Map<String, String> constants = _constants,
  List<BossProject> projects = const [],
  ProjectPickPurpose purpose = ProjectPickPurpose.confirm,
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogProjectPickerDialog.show(
              context: context,
              csvProjectName: _csvName,
              constants: constants,
              projects: projects,
              purpose: purpose,
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

/// 造一批互不相像的项目，用来验证搜索与「不预选」。
List<BossProject> manyProjects(int count) => List.generate(
  count,
  (i) => BossProject(id: 'PROJECT_$i', name: '独立系统$i号'),
);

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

      expect(find.textContaining('没能扫到 BOSS 的项目清单'), findsOneWidget);
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

    testWidgets('默认选中当前配置所属的项目，并标明它含审核人配置', (tester) async {
      await pumpDialog(tester, projects: _projects);

      expect(find.textContaining('当前用的就是它'), findsOneWidget);
      // 默认选中它，因此不该出现「你选的不是当前这份配置所属的项目」的警告
      expect(find.textContaining('你选的不是当前'), findsNothing);
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

      expect(find.textContaining('审核人仍沿用'), findsOneWidget);
      expect(find.textContaining('张三'), findsOneWidget);
    });

    testWidgets('选中的就是当前那个时不回传，避免覆盖完整配置', (tester) async {
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

  group('不替用户预选', () {
    testWidgets('当前配置不在清单里、也没有写法相同的，就一个都不选', (tester) async {
      // 预选就是一次默认同意。「看着像」恰恰是这套机制要防的东西，
      // 拿它当默认值等于把静默绑错换身衣服重来一遍。
      await pumpDialog(
        tester,
        constants: const {'projectId': 'PROJECT_不在清单里'},
        projects: manyProjects(3),
      );

      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    });

    testWidgets('一个都没选时不许点「就用选中的」', (tester) async {
      final answer = await pumpDialog(
        tester,
        constants: const {'projectId': 'PROJECT_不在清单里'},
        projects: manyProjects(3),
      );

      await tester.tap(find.text('就用选中的'));
      await tester.pumpAndSettle();

      // 按钮是禁用的，框还在，什么都没返回
      expect(answer.value, isNull);
      expect(find.text('选择 BOSS 里的项目'), findsOneWidget);
    });

    testWidgets('只是空格或全半角不同时可以预选', (tester) async {
      // 这一档没有歧义，仍然要用户点一下确定，但不必逼他先找一遍
      await pumpDialog(
        tester,
        constants: const {'projectId': 'PROJECT_不在清单里'},
        projects: const [BossProject(id: 'PROJECT_x', name: '面向比亚迪公司的项目 -自筹')],
      );

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    });
  });

  group('搜索', () {
    testWidgets('项目少时不显示搜索框，免得碍事', (tester) async {
      await pumpDialog(tester, projects: _projects);

      expect(find.widgetWithText(TextField, '搜索项目名'), findsNothing);
    });

    testWidgets('项目多时给搜索框，并按关键词过滤', (tester) async {
      await pumpDialog(
        tester,
        projects: manyProjects(WorkLogProjectPickerDialog.searchThreshold + 1),
      );

      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '系统2号');
      await tester.pumpAndSettle();

      expect(find.text('独立系统2号'), findsOneWidget);
      expect(find.text('独立系统3号'), findsNothing);
    });

    testWidgets('搜不到时说清楚是搜的结果，不是没扫到项目', (tester) async {
      await pumpDialog(
        tester,
        projects: manyProjects(WorkLogProjectPickerDialog.searchThreshold + 1),
      );

      await tester.enterText(find.byType(TextField), '压根不存在');
      await tester.pumpAndSettle();

      expect(find.textContaining('没有名称含「压根不存在」的项目'), findsOneWidget);
    });
  });

  group('用户主动改选', () {
    testWidgets('标题与按钮换成改选的措辞', (tester) async {
      await pumpDialog(
        tester,
        projects: _projects,
        purpose: ProjectPickPurpose.change,
      );

      expect(find.text('改选项目'), findsOneWidget);
      expect(find.text('改用选中的'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 是用户自己点进来的，不该再说「BOSS 里没有同名项目」
      expect(find.textContaining('BOSS 里没有与它同名'), findsNothing);
    });

    testWidgets('是用户自己发起的，点框外取消很自然', (tester) async {
      final answer = await pumpDialog(
        tester,
        projects: _projects,
        purpose: ProjectPickPurpose.change,
      );

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('改选项目'), findsNothing);
      expect(answer.value!.confirmed, isFalse);
    });
  });

  testWidgets('必须先定下来时，点框外不能糊弄过去', (tester) async {
    // 绑错项目的后果是工时记到别人名下，必须是一次明确的选择
    final answer = await pumpDialog(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('选择 BOSS 里的项目'), findsOneWidget);
    expect(answer.value, isNull);
  });
}
