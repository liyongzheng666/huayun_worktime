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
  double? existingHours,
  Map<String, String> constants = const {'auditorName': '张三'},
  bool canChangeProject = false,
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await WorkLogConfirmDialog.show(
              context: context,
              date: '2026-08-11',
              entry: _entry,
              hours: hours,
              existingHours: existingHours,
              constants: constants,
              canChangeProject: canChangeProject,
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
        constants: const {
          'auditorName': '张三',
          'projectName': '某项目(2)',
        },
      );

      expect(find.text('某项目(2)'), findsOneWidget);
      expect(
        find.text('CSV 里写的是「某项目」，已按 BOSS 的名称提交'),
        findsOneWidget,
      );
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
}
