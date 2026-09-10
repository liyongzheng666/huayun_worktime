import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/storage_keys.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/screens/daily_hours_screen.dart';
import 'package:hikiot_worktime/services/daily_attendance_repository.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/today_wrap_up_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/widgets/ios_workbench.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AttendanceRepository extends DailyAttendanceRepository {
  final loadedDates = <DateTime>[];
  Completer<void>? pendingLoad;

  @override
  Future<DailyAttendanceLoadResult> load(
    DateTime selectedDate, {
    DateTime? workDate,
  }) async {
    loadedDates.add(selectedDate);
    await pendingLoad?.future;
    return const DailyAttendanceLoadResult(
      status: DailyAttendanceLoadStatus.loaded,
      teamNo: 'test-team',
      holidayPlan: {},
      dayData: {'type': '工作日', 'hours': 8.0},
      attendanceData: {
        'checkInTime': '08:30',
        'checkOutTime': '18:30',
        'hours': 8.0,
      },
      pinnedTarget: null,
      baseTarget: 120,
      minTarget: 100,
    );
  }
}

class _WrapUpService extends TodayWrapUpService {
  _WrapUpService(this.clock);

  final DateTime Function() clock;
  int cacheCalls = 0;
  int queryCalls = 0;
  bool storageFails = false;
  double hours = 8;
  WorkLogEntry? entry;
  Completer<TodayWrapUpData>? pendingQuery;

  @override
  Future<TodayWrapUpData> loadCached(DateTime date) async {
    cacheCalls++;
    if (storageFails) throw StateError('local storage unavailable');
    return TodayWrapUpData(date: date, hasEntry: true, entry: entry);
  }

  @override
  Future<TodayWrapUpData> load(DateTime date) async {
    queryCalls++;
    if (pendingQuery != null) return pendingQuery!.future;
    return TodayWrapUpData(
      date: date,
      hasEntry: true,
      entry: entry,
      bossStatus: hours > 0
          ? TodayBossStatus.submitted
          : TodayBossStatus.unsubmitted,
      bossHours: hours,
      checkedAt: clock(),
    );
  }
}

void main() {
  late DateTime now;
  late _WrapUpService service;

  setUp(() {
    final today = DateTime.now();
    now = DateTime(today.year, today.month, today.day, 19);
    SharedPreferences.setMockInitialValues({
      StorageKeys.onboardingCompleted: true,
    });
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.ios();
    service = _WrapUpService(() => now);
  });

  tearDown(() {
    PlatformCapabilities.debugOverride = null;
  });

  // 限量推进异步存储和页面绘制，不等待今日卡的到期计时器。
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    Future<void> Function(TodayWrapUpAction, DateTime)? onAction,
    _AttendanceRepository? repository,
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: DailyHoursScreen(
          dailyRepository: repository ?? _AttendanceRepository(),
          todayWrapUpService: service,
          wrapUpClock: () => now,
          onWrapUpAction: onAction,
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('Android 首页不展示今日卡，也不读取素材或查询 BOSS', (tester) async {
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await pumpScreen(tester);
    expect(find.byType(IosWorkbench), findsNothing);
    expect(service.cacheCalls, 0);
    expect(service.queryCalls, 0);
    await disposeScreen(tester);
  });

  testWidgets('iOS 今日 CTA 传递当前日期，等待处理期间不重复调用', (tester) async {
    service.hours = 0;
    final actionDone = Completer<void>();
    final actions = <TodayWrapUpAction>[];
    final dates = <DateTime>[];
    await pumpScreen(
      tester,
      onAction: (action, date) {
        actions.add(action);
        dates.add(date);
        return actionDone.future;
      },
    );
    expect(find.byType(IosWorkbench), findsOneWidget);
    expect(find.text('检查并提交'), findsOneWidget);
    final button = find.descendant(
      of: find.byType(IosWorkbench),
      matching: find.byType(FilledButton),
    );
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(actions, [TodayWrapUpAction.reviewLog]);
    expect(DateHelper.isSameDay(dates.single, now), isTrue);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    actionDone.complete();
    await flush(tester);
    expect(service.queryCalls, 2);
    await disposeScreen(tester);
  });

  testWidgets('首页静置 15 分钟后主动将已提交状态降为待确认', (tester) async {
    await pumpScreen(tester);
    expect(find.textContaining('今日日志已提交', findRichText: true), findsOneWidget);
    now = now.add(TodayWrapUpData.freshness);
    await tester.pump(TodayWrapUpData.freshness);
    expect(
      find.textContaining('日志提交状态待确认', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('刷新确认'), findsOneWidget);
    expect(service.queryCalls, 1);
    await disposeScreen(tester);
  });

  testWidgets('跨午夜隐藏昨日今日卡，保留正在查看的日期', (tester) async {
    now = DateTime(now.year, now.month, now.day, 23, 59);
    await pumpScreen(tester);
    final state = tester.state<DailyHoursScreenState>(
      find.byType(DailyHoursScreen),
    );
    final selectedDate = state.selectedDate;
    expect(find.byType(IosWorkbench), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.byType(IosWorkbench), findsNothing);
    expect(state.selectedDate, selectedDate);
    expect(service.queryCalls, 1);
    await disposeScreen(tester);
  });

  testWidgets('素材存储读取失败提供重试，恢复后展示状态且不冒泡异常', (tester) async {
    service.storageFails = true;
    await pumpScreen(tester);
    expect(find.text('暂时没查清楚，点右上角刷新后再确认。'), findsOneWidget);
    expect(service.queryCalls, 0);
    expect(tester.takeException(), isNull);
    service.storageFails = false;
    await tester.tap(find.text('刷新确认'));
    await flush(tester);
    expect(find.byType(IosWorkbench), findsOneWidget);
    expect(service.queryCalls, 1);
    await disposeScreen(tester);
  });

  testWidgets('BOSS 查询尚未完成就跨午夜时隐藏卡片，迟到结果不复活昨日卡', (tester) async {
    now = DateTime(now.year, now.month, now.day, 23, 59);
    final queryDate = now;
    final pending = Completer<TodayWrapUpData>();
    service.pendingQuery = pending;
    await pumpScreen(tester);
    expect(service.queryCalls, 1);
    expect(find.byType(IosWorkbench), findsOneWidget);
    expect(find.text('正在更新…'), findsNWidgets(2));

    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.byType(IosWorkbench), findsNothing);

    pending.complete(
      TodayWrapUpData(
        date: queryDate,
        hasEntry: true,
        bossStatus: TodayBossStatus.submitted,
        bossHours: 8,
        checkedAt: now,
      ),
    );
    await flush(tester);
    expect(find.byType(IosWorkbench), findsNothing);
    expect(find.textContaining('今日日志已提交', findRichText: true), findsNothing);
    expect(service.queryCalls, 1);
    await disposeScreen(tester);
  });
  testWidgets('未来日期回调不切换日期，也不触发考勤和日志查询', (tester) async {
    final repository = _AttendanceRepository();
    await pumpScreen(tester, repository: repository);
    final state = tester.state<DailyHoursScreenState>(
      find.byType(DailyHoursScreen),
    );
    final selectedDate = state.selectedDate;
    final workbench = tester.widget<IosWorkbench>(find.byType(IosWorkbench));
    workbench.onSelectDate(DateTime(now.year, now.month, now.day + 1));
    await flush(tester);
    expect(state.selectedDate, selectedDate);
    expect(repository.loadedDates, [selectedDate]);
    expect(service.queryCalls, 1);
    expect(find.byType(IosWorkbench), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('跨日切到今天且考勤查询挂起时，不展示昨日素材和同步时间', (tester) async {
    final repository = _AttendanceRepository();
    service.entry = WorkLogEntry(
      date: DateHelper.formatDate(now),
      projectName: '昨日项目',
      workType: '开发',
      stage: '开发',
      activity: '编码',
      title: '昨天的日志标题',
      content: '昨天的日志内容',
    );
    await pumpScreen(tester, repository: repository);
    final previous = tester.widget<IosWorkbench>(find.byType(IosWorkbench));
    expect(previous.entry?.title, '昨天的日志标题');
    expect(previous.updatedAt, now);
    now = DateTime(now.year, now.month, now.day + 1, 9);
    final pending = Completer<void>();
    repository.pendingLoad = pending;
    previous.onSelectDate(DateTime(now.year, now.month, now.day));
    await flush(tester);
    final current = tester.widget<IosWorkbench>(find.byType(IosWorkbench));
    expect(current.isRefreshing, isTrue);
    expect(current.entry, isNull);
    expect(current.updatedAt, isNull);
    expect(current.summary, isNull);
    expect(find.text('昨天的日志标题'), findsNothing);
    expect(find.text('昨天的日志内容'), findsNothing);
    service.entry = null;
    pending.complete();
    await flush(tester);
    expect(repository.loadedDates.length, 2);
    expect(service.queryCalls, 2);
    await disposeScreen(tester);
  });

  testWidgets('保存请假及恢复默认后，首页立即复算月累计且不增加网络查询', (tester) async {
    final previousHapticMode = HapticUtils.mode;
    await HapticUtils.setMode(HapticMode.off);
    addTearDown(() => HapticUtils.setMode(previousHapticMode));
    final storage = StorageService();
    await storage.saveMonthlyData('test-team', DateHelper.formatMonth(now), {
      for (var day = 1; day <= now.day; day++)
        DateHelper.formatDate(DateTime(now.year, now.month, day)): {
          'type': '工作日',
          'hours': 8.0,
          'dataSourceStatus': 'apiConfirmed',
        },
    });
    final repository = _AttendanceRepository();
    await pumpScreen(tester, repository: repository);
    IosWorkbench workbench() =>
        tester.widget<IosWorkbench>(find.byType(IosWorkbench));
    final initialHours = now.day * 8.0;
    expect(workbench().monthHours, initialHours);
    workbench().onEditAttendance();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '请假'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '请假')).selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(workbench().monthHours, initialHours - 8);
    expect(
      (await storage.loadCalendarMarks('test-team'))[DateHelper.formatDate(
        now,
      )]?['type'],
      '请假',
    );
    workbench().onEditAttendance();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(workbench().monthHours, initialHours);
    expect(
      (await storage.loadCalendarMarks(
        'test-team',
      )).containsKey(DateHelper.formatDate(now)),
      isFalse,
    );
    expect(repository.loadedDates.length, 1);
    expect(service.queryCalls, 1);
    await disposeScreen(tester);
  });
}
