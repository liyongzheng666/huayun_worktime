import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/widgets/work_log_confirm_dialog.dart';

const _entry = WorkLogEntry(
  date: '2026-08-11',
  projectName: '某项目',
  workType: '开发',
  stage: '实现',
  activity: '编码',
  title: '标题',
  content: '工作内容',
);

/// 承接 show() 的返回值，供点完按钮后断言。
class Answer {
  WorkLogConfirmOutcome? value;
  bool returned = false;
}

/// 把确认框推起来，返回后可直接对文案做断言。
Future<Answer> pumpDialog(
  WidgetTester tester, {
  required WorkLogHours hours,
  double? existingHours = 0,
  Map<String, String> constants = const {'auditorName': '张三'},
  bool canChangeProject = false,
  bool canChangeAuditor = false,
  String date = '2026-08-11',
  DateTime? now,
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogConfirmDialog.show(
              context: context,
              date: date,
              entry: _entry,
              hours: hours,
              existingHours: existingHours,
              constants: constants,
              canChangeProject: canChangeProject,
              canChangeAuditor: canChangeAuditor,
              now: now,
            );
            answer.returned = true;
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
  group('提交前去重', () {
    testWidgets('该日已有日志时不再提供继续提交入口', (tester) async {
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        existingHours: 8,
      );

      expect(find.textContaining('这一天在 BOSS 已填报 8.00 小时'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '该日已提交'),
      );
      expect(button.onPressed, isNull);
      expect(answer.returned, isFalse);
    });

    testWidgets('查询结果未知时暂缓提交', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        existingHours: null,
      );

      expect(find.textContaining('本次将暂缓提交'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '暂缓提交'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('明确查到零工时才允许确认提交', (tester) async {
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        existingHours: 0,
      );

      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(answer.value?.actWork, '8.00');
    });
  });

  group('凑整建议', () {
    testWidgets('11.55 小时提示还差 3 分钟到 11.60', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.55,
          checkIn: '08:30',
          checkOut: '20:33',
        ),
      );

      expect(find.text('💡 再待 3 分钟可凑满 11.60 小时'), findsOneWidget);
    });

    testWidgets('给出具体打卡到几点，而不是只说还差几分钟', (tester) async {
      // 「再待 3 分钟」要能照着做，就得知道待到几点
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.55,
          checkIn: '08:30',
          checkOut: '20:33',
        ),
      );

      expect(find.text('打卡到 20:36 后下拉刷新本页，再提交'), findsOneWidget);
    });

    testWidgets('已落在 0.1 刻度上时不提示等待', (tester) async {
      // 跳到下一档会让用户凭空多等 6 分钟
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.6,
          checkIn: '08:30',
          checkOut: '20:36',
        ),
      );

      expect(find.textContaining('再待'), findsNothing);
      expect(find.text('工时已是 0.1 小时的整数倍，不用再等'), findsOneWidget);
    });

    testWidgets('没有下班打卡时只给分钟数，不编造打卡时刻', (tester) async {
      await pumpDialog(tester, hours: const WorkLogHours(hours: 11.55));

      expect(find.text('💡 再待 3 分钟可凑满 11.60 小时'), findsOneWidget);
      expect(find.textContaining('后下拉刷新本页'), findsNothing);
    });

    testWidgets('工时非法时不给凑整建议', (tester) async {
      // 此时提交按钮本就是灰的，凑整建议只会喧宾夺主
      await pumpDialog(tester, hours: const WorkLogHours());
      await tester.enterText(find.byType(TextField), '99');
      await tester.pump();

      expect(find.textContaining('再待'), findsNothing);
      expect(find.textContaining('不用再等'), findsNothing);
    });

    testWidgets('建议跟着输入框走，手改工时后不再盯着打卡值', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.55,
          checkIn: '08:30',
          checkOut: '20:33',
        ),
      );
      expect(find.text('💡 再待 3 分钟可凑满 11.60 小时'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '8.55');
      await tester.pump();

      // 8.55 距 8.6 还差 3 分钟；仍报 11.60 就是拿旧打卡值在算
      expect(find.text('💡 再待 3 分钟可凑满 8.60 小时'), findsOneWidget);
      expect(find.textContaining('11.60'), findsNothing);
    });

    testWidgets('手改工时后不再给打卡时刻，避免指向错误的时间', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.55,
          checkIn: '08:30',
          checkOut: '20:33',
        ),
      );

      await tester.enterText(find.byType(TextField), '8.55');
      await tester.pump();

      expect(find.textContaining('后下拉刷新本页'), findsNothing);
    });

    testWidgets('提示不改动工时输入框，提交的仍是实际打卡值', (tester) async {
      // 替用户把 11.55 改成 11.60 就是虚报，这条锁死
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 11.55,
          checkIn: '08:30',
          checkOut: '20:33',
        ),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '11.55');
    });
  });

  group('项目行', () {
    testWidgets('显示 BOSS 的项目名，并标出 CSV 的写法', (tester) async {
      // 提交上去的是 BOSS 的名字，界面就得显示它；
      // 同时把 CSV 的写法标出来，用户才可能发现绑错了项目
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {'auditorName': '张三', 'projectName': '某项目(2)'},
      );

      expect(find.text('某项目(2)'), findsOneWidget);
      expect(find.text('CSV 里写的是「某项目」，已按 BOSS 的名称提交'), findsOneWidget);
    });

    testWidgets('两边名字一致时不啰嗦', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {'auditorName': '张三', 'projectName': '某项目'},
      );

      expect(find.text('某项目'), findsOneWidget);
      expect(find.textContaining('CSV 里写的是'), findsNothing);
    });

    testWidgets('手工配置没有 BOSS 名时退回 CSV 的写法', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {'auditorName': '张三'},
      );

      expect(find.text('某项目'), findsOneWidget);
      expect(find.textContaining('CSV 里写的是'), findsNothing);
    });

    testWidgets('没有 BOSS 名时必须说破，并把项目 ID 摆出来', (tester) async {
      // 实际踩过：没有 BOSS 名时界面只显示 CSV 的写法且不加任何提示，
      // 看起来完全正常，用户于是把日志提交到了别的项目下也毫无察觉。
      // 没有任何东西能证明这个名字和 PROJECTID 指向同一个项目。
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {'auditorName': '张三', 'projectId': 'PROJECT_aaa'},
      );

      expect(find.textContaining('未能确认 BOSS 那边的项目名'), findsOneWidget);
      expect(find.textContaining('PROJECT_aaa'), findsOneWidget);
    });

    testWidgets('有 BOSS 名时不挂这条警告，免得喧宾夺主', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {
          'auditorName': '张三',
          'projectId': 'PROJECT_aaa',
          'projectName': '某项目(2)',
        },
      );

      expect(find.textContaining('未能确认 BOSS 那边的项目名'), findsNothing);
    });
  });

  group('改选项目入口', () {
    testWidgets('没有项目清单时不给「改选」，点开也没得选', (tester) async {
      await pumpDialog(tester, hours: const WorkLogHours(hours: 8));

      expect(find.text('改选'), findsNothing);
    });

    testWidgets('有清单时给「改选」，点了就把这个诉求带回去', (tester) async {
      // 项目一旦绑定就不再询问，当初绑错了的话这里是用户唯一能自己纠正的地方
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        canChangeProject: true,
      );

      await tester.tap(find.text('改选'));
      await tester.pumpAndSettle();

      expect(answer.value!.changeProject, isTrue);
      expect(answer.value!.actWork, isNull);
    });

    testWidgets('正常确认提交时不带改选诉求，且回传工时', (tester) async {
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        canChangeProject: true,
      );

      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();

      expect(answer.value!.changeProject, isFalse);
      expect(answer.value!.actWork, '8.00');
    });

    testWidgets('审核人也能改选，并带回对应诉求', (tester) async {
      // 审核人和项目是这个框里并列的两个「填错就有实际后果」的字段，
      // 都不是用户输入的，因此都必须能核对、也都必须能改
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        canChangeAuditor: true,
      );

      await tester.tap(find.text('改选'));
      await tester.pumpAndSettle();

      expect(answer.value!.changeAuditor, isTrue);
      expect(answer.value!.changeProject, isFalse);
    });

    testWidgets('审核人只有 ID 没有姓名时要说破', (tester) async {
      // 显示成空白会让人以为是渲染问题，而这里的空白恰恰意味着
      // 没法用肉眼核对是不是对的人
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {'auditor': ';USERINFO_ccc'},
      );

      expect(find.textContaining('没法用姓名核对'), findsOneWidget);
    });

    testWidgets('完全没有审核人时直说无法提交', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        constants: const {},
      );

      expect(find.textContaining('还没有审核人，无法提交'), findsOneWidget);
    });

    testWidgets('取消返回空，两种诉求都不是', (tester) async {
      final answer = await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 8),
        canChangeProject: true,
      );

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue);
      expect(answer.value, isNull);
    });
  });

  group('工时来源切换（打卡 / 当前时间）', () {
    // 时间全部注入，测试不依赖「今天恰好是几号」「此刻几点」
    final today = DateTime(2026, 8, 11, 14, 0);
    const todayStr = '2026-08-11';

    // 08:30 上班，注入的此刻是 14:00 → 5.5 小时扣 1 小时午休 = 4.50
    const punched = WorkLogHours(
      hours: 3.0,
      checkIn: '08:30',
      checkOut: '11:30',
    );

    testWidgets('今天且有上班打卡时给出两个来源，各自标出小时数', (tester) async {
      // 切换前就能看清两边差多少，不用切过去才知道
      await pumpDialog(tester, hours: punched, date: todayStr, now: today);

      expect(find.text('工时来源'), findsOneWidget);
      expect(find.text('打卡 3.00 h'), findsOneWidget);
      expect(find.text('当前时间 4.50 h'), findsOneWidget);
    });

    testWidgets('默认按打卡，输入框是打卡值', (tester) async {
      await pumpDialog(tester, hours: punched, date: todayStr, now: today);

      expect(find.widgetWithText(TextField, '3.00'), findsOneWidget);
      expect(find.textContaining('来自打卡工时'), findsOneWidget);
    });

    testWidgets('切到当前时间后，输入框跟着变成按此刻算的值', (tester) async {
      final answer = await pumpDialog(
        tester,
        hours: punched,
        date: todayStr,
        now: today,
      );

      await tester.tap(find.text('当前时间 4.50 h'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '4.50'), findsOneWidget);
      expect(find.textContaining('来自按当前时间'), findsOneWidget);

      // 提交出去的必须是切换后的值
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(answer.value!.actWork, '4.50');
    });

    testWidgets('能切回打卡，值也跟着回去', (tester) async {
      // 「自由切换」意味着来回都得成立，不是单向的
      await pumpDialog(tester, hours: punched, date: todayStr, now: today);

      await tester.tap(find.text('当前时间 4.50 h'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打卡 3.00 h'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '3.00'), findsOneWidget);
      expect(find.textContaining('来自打卡工时'), findsOneWidget);
    });

    testWidgets('切换后不该还挂着「已手动调整」', (tester) async {
      // 判定基准要跟着来源走，否则切一次就永远显示已调整
      await pumpDialog(tester, hours: punched, date: todayStr, now: today);

      await tester.tap(find.text('当前时间 4.50 h'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已手动调整'), findsNothing);
    });

    testWidgets('切换会覆盖手改的值——点开关就是要求按该来源重算', (tester) async {
      await pumpDialog(tester, hours: punched, date: todayStr, now: today);

      await tester.enterText(find.byType(TextField), '7.77');
      await tester.pumpAndSettle();
      expect(find.textContaining('已手动调整'), findsOneWidget);

      await tester.tap(find.text('当前时间 4.50 h'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '4.50'), findsOneWidget);
    });

    testWidgets('不是今天就不给这个开关', (tester) async {
      // 拿此刻去减一个过去日期的上班时间，算出来的是个毫无意义的大数
      await pumpDialog(tester, hours: punched, date: '2026-08-10', now: today);

      expect(find.text('工时来源'), findsNothing);
      expect(find.textContaining('当前时间'), findsNothing);
    });

    testWidgets('没有上班打卡时不给这个开关', (tester) async {
      await pumpDialog(
        tester,
        hours: const WorkLogHours(hours: 3.0),
        date: todayStr,
        now: today,
      );

      expect(find.text('工时来源'), findsNothing);
    });

    testWidgets('没有打卡工时但有上班卡时，仍可按当前时间报', (tester) async {
      // 只打了上班卡、还没下班卡，正是这个功能最该管用的场景
      await pumpDialog(
        tester,
        hours: const WorkLogHours(checkIn: '08:30'),
        date: todayStr,
        now: today,
      );

      expect(find.text('打卡（无数据）'), findsOneWidget);
      await tester.tap(find.text('当前时间 4.50 h'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '4.50'), findsOneWidget);
    });

    testWidgets('按当前时间时，凑整提示从此刻起算而不是下班打卡', (tester) async {
      // 给错了，「打卡到几点」会指向一个用户照着做反而更错的时间
      await pumpDialog(
        tester,
        hours: const WorkLogHours(
          hours: 3.0,
          checkIn: '08:25',
          checkOut: '11:30',
        ),
        date: todayStr,
        now: DateTime(2026, 8, 11, 14, 0),
      );

      await tester.tap(find.textContaining('当前时间'));
      await tester.pumpAndSettle();

      // 08:25 → 14:00 共 335 分钟，扣 60 分钟午休 = 275 分钟 = 4.58 小时。
      // 275 距下一个 6 分钟刻度（276）差 1 分钟，且必须从 14:00 起算。
      expect(find.textContaining('再待 1 分钟'), findsOneWidget);
      expect(find.textContaining('14:01'), findsOneWidget);
    });
  });
}
