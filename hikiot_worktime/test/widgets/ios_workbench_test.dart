import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/widgets/ios_workbench.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _summary = TodayWrapUpSummary(
  title: '今天辛苦啦',
  subtitle: '看一眼进度，少惦记一件事',
  attendance: TodayWrapUpItem(
    label: '上下班记录已查到',
    detail: '请按实际班次核对',
    status: TodayWrapUpItemStatus.complete,
  ),
  csv: TodayWrapUpItem(
    label: '今日日志素材已准备好',
    detail: '提交前再核对项目与审核人',
    status: TodayWrapUpItemStatus.complete,
  ),
  submission: TodayWrapUpItem(
    label: '日志提交状态待确认',
    detail: '暂时没查清楚，请刷新确认',
    status: TodayWrapUpItemStatus.unknown,
  ),
  primaryAction: TodayWrapUpAction.refresh,
  actionLabel: '刷新确认',
);

Future<void> _pump(
  WidgetTester tester, {
  bool refreshing = false,
  bool failed = false,
  bool attendanceFailed = false,
  TodayWrapUpSummary? summary = _summary,
  VoidCallback? onRefresh,
  ValueChanged<TodayWrapUpAction>? onAction,
  ValueChanged<DateTime>? onDate,
  VoidCallback? onEdit,
  double width = 390,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.reset();
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.iOS,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4c7b2e),
          brightness: brightness,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: IosWorkbench(
            selectedDate: DateTime(2026, 9, 10),
            today: DateTime(2026, 9, 10),
            hours: 8.567,
            attendanceData: const {
              'checkInTime': '08:30',
              'checkOutTime': '17:30',
            },
            summary: summary,
            entry: const WorkLogEntry(
              date: '2026-09-10',
              projectName: '真实项目',
              workType: '',
              stage: '',
              activity: '',
              title: '真实日志标题',
              content: '真实工作内容',
            ),
            isRefreshing: refreshing,
            loadFailed: failed,
            attendanceFailed: attendanceFailed,
            onRefresh: onRefresh ?? () {},
            onSelectDate: onDate ?? (_) {},
            onAction: onAction ?? (_) {},
            onEditAttendance: onEdit ?? () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  final haptics = <MethodCall>[];
  Completer<void>? hapticGate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HapticUtils.setMode(HapticMode.advanced);
    haptics.clear();
    hapticGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call);
            await hapticGate?.future;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('真实日志和截断工时正确展示，未知月累计保持未知', (tester) async {
    await _pump(tester);
    expect(find.text('8.56'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('真实日志标题'), findsOneWidget);
    expect(find.text('真实项目'), findsOneWidget);
    expect(find.text('2 / 3 已确认完成'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    expect(find.text('尚未同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('周日期和主操作交还调用方', (tester) async {
    DateTime? selected;
    TodayWrapUpAction? action;
    await _pump(
      tester,
      onDate: (value) => selected = value,
      onAction: (value) => action = value,
    );
    await tester.tap(find.byKey(const ValueKey('workbench-date-2026-09-09')));
    expect(selected, DateTime(2026, 9, 9));
    final button = find.byKey(const ValueKey('ios-workbench-action'));
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
    expect(action, TodayWrapUpAction.refresh);
    expect(haptics.map((call) => call.arguments), [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
    ]);
  });

  testWidgets('未来日期不可点击，不会交给历史页触发日期选择断言', (tester) async {
    DateTime? selected;
    await _pump(tester, onDate: (value) => selected = value);
    final future = find.byKey(const ValueKey('workbench-date-2026-09-11'));
    expect(tester.widget<TextButton>(future).onPressed, isNull);
    await tester.tap(future);
    expect(selected, isNull);
    await tester.tap(find.byKey(const ValueKey('workbench-date-2026-09-10')));
    expect(selected, isNull);
    expect(haptics, isEmpty);
  });

  testWidgets('滚动内容时主操作仍固定在屏幕底部', (tester) async {
    await _pump(tester, width: 320, textScale: 2);
    final button = find.byKey(const ValueKey('ios-workbench-action'));
    final original = tester.getCenter(button);
    expect(button.hitTestable(), findsOneWidget);
    expect(haptics, isEmpty);
    await tester.drag(
      find.byKey(const ValueKey('ios-workbench-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.getCenter(button), original);
    expect(button.hitTestable(), findsOneWidget);
  });

  testWidgets('刷新中禁用重复刷新、提交和考勤编辑', (tester) async {
    var count = 0;
    await _pump(
      tester,
      refreshing: true,
      onRefresh: () => count++,
      onAction: (_) => count++,
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('ios-workbench-action')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '核对工时与类型'))
          .onPressed,
      isNull,
    );
    expect(count, 0);
    await tester.tap(find.byKey(const ValueKey('ios-workbench-action')));
    await tester.tap(find.byType(IconButton));
    await tester.tap(find.widgetWithText(TextButton, '核对工时与类型'));
    expect(haptics, isEmpty);
  });

  testWidgets('刷新与考勤编辑各反馈一次，触觉完成前业务已经执行', (tester) async {
    var refreshed = 0;
    var edited = 0;
    hapticGate = Completer<void>();
    await _pump(tester, onRefresh: () => refreshed++, onEdit: () => edited++);
    await tester.tap(find.byTooltip('刷新今日状态'));
    expect(refreshed, 1);
    await tester.tap(find.widgetWithText(TextButton, '核对工时与类型'));
    expect(edited, 1);
    expect(haptics.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.lightImpact',
    ]);
    hapticGate!.complete();
    await tester.pump();
  });

  testWidgets('关闭触觉仍可操作工作台且不调用震动通道', (tester) async {
    await HapticUtils.setMode(HapticMode.off);
    var count = 0;
    await _pump(
      tester,
      onRefresh: () => count++,
      onEdit: () => count++,
      onAction: (_) => count++,
      onDate: (_) => count++,
    );
    await tester.tap(find.byTooltip('刷新今日状态'));
    await tester.tap(find.widgetWithText(TextButton, '核对工时与类型'));
    await tester.tap(find.byKey(const ValueKey('ios-workbench-action')));
    await tester.tap(find.byKey(const ValueKey('workbench-date-2026-09-09')));
    expect(count, 4);
    expect(haptics, isEmpty);
  });

  testWidgets('没有汇总和查询失败不会误报工时或完成，主操作可重试', (tester) async {
    var refreshCount = 0;
    await _pump(
      tester,
      summary: null,
      failed: true,
      attendanceFailed: true,
      onRefresh: () => refreshCount++,
    );
    expect(find.text('0 / 3 已确认完成'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('更新未完成'), findsOneWidget);
    final button = find.byKey(const ValueKey('ios-workbench-action'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    expect(refreshCount, 1);
  });

  testWidgets('刷新日志和素材查询失败不清空已确认考勤工时', (tester) async {
    await _pump(tester, refreshing: true, failed: true);
    expect(find.text('8.56'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('320宽大字体明暗主题无溢出，底部动作可滚动触达', (tester) async {
    for (final brightness in Brightness.values) {
      await _pump(tester, width: 320, textScale: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('ios-workbench-action')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}
