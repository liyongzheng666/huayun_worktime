import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/work_log_screen.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/widgets/week_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _reportedHours = find.byKey(const ValueKey('reported-boss-hours'));

class _CountingWorkLogRepository extends WorkLogRepository {
  _CountingWorkLogRepository({super.loadWorkHours});

  int weekCalls = 0;

  @override
  Future<List<WorkLogDaySummary>> loadWeek(DateTime date) {
    weekCalls++;
    return super.loadWeek(date);
  }
}

// 测试需检查监听是否真正移除，仅断言“不抛错”无法发现静默泄漏。
bool get _hasBossListeners =>
    // ignore: invalid_use_of_protected_member
    StorageService.bossHoursChanges.hasListeners;

String? reportedText(WidgetTester tester) =>
    tester.widget<Text>(_reportedHours).data;

Future<void> pumpLog(WidgetTester tester, BossDayLoader loader) async {
  await tester.binding.setSurfaceSize(const Size(900, 1300));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: WorkLogScreen(
        repository: WorkLogRepository(
          loadWorkHours: (_) async => const WorkLogHours(hours: 8),
        ),
        bossAutoRefresh: BossHoursAutoRefreshService(loadDay: loader),
      ),
    ),
  );
  // 留出异步缓存读取的帧，不等待尚未完成的查询进度动画。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> selectDay(WidgetTester tester, DateTime date) async {
  final day = find.descendant(
    of: find.byType(WeekStrip),
    matching: find.text('${date.day}'),
  );
  await tester.ensureVisible(day);
  await tester.tap(day);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late DateTime today;
  late String dateKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService().saveToken('test-token');
    await StorageService().saveTeamContext(
      teamNo: 'test-team',
      personNo: 'test-person',
    );
    await HapticUtils.setMode(HapticMode.off);
    today = DateHelper.getWorkDate();
    dateKey = DateHelper.formatDate(today);
  });

  tearDown(() async {
    await HapticUtils.setMode(HapticMode.advanced);
  });

  testWidgets('隐藏日志页不预加载，激活后由主框架刷新才各查询一次', (tester) async {
    var workHoursRequests = 0;
    var bossRequests = 0;
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    final repository = _CountingWorkLogRepository(
      loadWorkHours: (_) async {
        workHoursRequests++;
        return const WorkLogHours(hours: 8);
      },
    );
    final bossRefresh = BossHoursAutoRefreshService(
      loadDay: (_) async {
        bossRequests++;
        return const BossSessionResult(BossSessionStatus.ok, 6.5);
      },
    );
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, isActive, child) => WorkLogScreen(
            isActive: isActive,
            repository: repository,
            bossAutoRefresh: bossRefresh,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(workHoursRequests, 0);
    expect(bossRequests, 0);
    expect(repository.weekCalls, 0);

    active.value = true;
    await tester.pumpAndSettle();
    expect(workHoursRequests, 0);
    expect(bossRequests, 0);
    expect(repository.weekCalls, 0);

    await tester
        .state<WorkLogScreenState>(find.byType(WorkLogScreen))
        .refreshData();
    await tester.pumpAndSettle();
    expect(workHoursRequests, 1);
    expect(bossRequests, 1);
    expect(reportedText(tester), '6.50 小时');
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开日志自动核对所选日期，已填报与打卡工时分别展示', (tester) async {
    final requested = <String>[];
    await pumpLog(tester, (date) async {
      requested.add(DateHelper.formatDate(date));
      return const BossSessionResult(BossSessionStatus.ok, 6.5);
    });
    await tester.pumpAndSettle();

    expect(requested, [dateKey]);
    expect(reportedText(tester), '6.50 小时');
    expect(find.text('BOSS 已填报'), findsOneWidget);
    expect(find.text('打卡工时'), findsOneWidget);
    expect(find.text('8.00'), findsOneWidget);
    expect(find.text('已填报 · 打开 BOSS 查看'), findsOneWidget);
    expect(find.text('提交 ${today.month}月${today.day}日 日志'), findsNothing);
  });

  testWidgets('BOSS 单日刷新成功仅通知周条重新读取一次', (tester) async {
    final reply = Completer<BossSessionResult<double>>();
    final repository = _CountingWorkLogRepository(
      loadWorkHours: (_) async => const WorkLogHours(hours: 8),
    );
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WorkLogScreen(
          repository: repository,
          bossAutoRefresh: BossHoursAutoRefreshService(
            loadDay: (_) => reply.future,
          ),
        ),
      ),
    );
    // 先让周条完成初次缓存读取，保留尚未完成的 BOSS 查询。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final initialWeekCalls = repository.weekCalls;
    expect(initialWeekCalls, greaterThan(0));
    reply.complete(const BossSessionResult(BossSessionStatus.ok, 6.5));
    await tester.pumpAndSettle();
    expect(repository.weekCalls, initialWeekCalls + 1);
    expect(reportedText(tester), '6.50 小时');
  });

  testWidgets('其他页面更新单日缓存后立即复读，不再发起网络查询', (tester) async {
    var requests = 0;
    await pumpLog(tester, (_) async {
      requests++;
      return const BossSessionResult(BossSessionStatus.ok, 6.5);
    });
    await tester.pumpAndSettle();
    expect(reportedText(tester), '6.50 小时');

    await StorageService().saveBossHoursForDate(dateKey, 7.25);
    await tester.pumpAndSettle();

    expect(reportedText(tester), '7.25 小时');
    expect(find.text('8.00'), findsOneWidget);
    expect(requests, 1);
    await StorageService().saveBossHoursForDate(dateKey, 0);
    await tester.pumpAndSettle();
    expect(reportedText(tester), '未填报');
    expect(find.text('已填报 · 打开 BOSS 查看'), findsNothing);
    expect(find.text('提交 ${today.month}月${today.day}日 日志'), findsOneWidget);
  });

  testWidgets('查询失败保留旧工时并说明上次已填报，不误显示零', (tester) async {
    await StorageService().saveBossHoursForDate(dateKey, 6.5);
    await pumpLog(
      tester,
      (_) async => const BossSessionResult(BossSessionStatus.failed),
    );
    await tester.pumpAndSettle();

    expect(reportedText(tester), '6.50 小时');
    expect(find.text('上次已填报'), findsOneWidget);
    expect(find.textContaining('本次未能更新'), findsOneWidget);
    expect(find.text('0.00 小时'), findsNothing);
  });

  testWidgets('确认未填报显示文字状态，打卡时长仍正常显示', (tester) async {
    await pumpLog(
      tester,
      (_) async => const BossSessionResult(BossSessionStatus.ok, 0),
    );
    await tester.pumpAndSettle();
    expect(reportedText(tester), '未填报');
    expect(find.text('华天日报'), findsOneWidget);
    expect(find.text('BOSS 已填报'), findsNothing);
    expect(find.text('0.00 小时'), findsNothing);
    expect(find.text('8.00'), findsOneWidget);
  });

  testWidgets('旧零合计本次查询失败显示待确认，不能显示已填0或当前未填', (tester) async {
    await StorageService().saveBossHoursForDate(
      dateKey,
      0,
      refreshedAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await pumpLog(
      tester,
      (_) async => const BossSessionResult(BossSessionStatus.failed),
    );
    await tester.pumpAndSettle();
    expect(reportedText(tester), '待确认');
    expect(find.text('BOSS 已填报'), findsNothing);
    expect(find.text('上次已填报'), findsNothing);
    expect(find.text('0.00 小时'), findsNothing);
  });

  testWidgets('已有历史日报ID但查询零合计提示核对，不冒充未填报', (tester) async {
    await StorageService().saveWorkLogObjectId(dateKey, 'WORKLOG_known');
    await pumpLog(
      tester,
      (_) async => const BossSessionResult(BossSessionStatus.ok, 0),
    );
    await tester.pumpAndSettle();
    expect(reportedText(tester), '已有日报记录，工时待核对');
    expect(find.text('0.00 小时'), findsNothing);
  });

  testWidgets('快速换日期后旧查询晚到不覆盖当前日期已填报工时', (tester) async {
    final firstReply = Completer<BossSessionResult<double>>();
    final secondReply = Completer<BossSessionResult<double>>();
    final nextDate = today.add(Duration(days: today.weekday == 7 ? -1 : 1));
    final nextKey = DateHelper.formatDate(nextDate);
    final requested = <String>[];
    await pumpLog(tester, (date) {
      final key = DateHelper.formatDate(date);
      requested.add(key);
      return key == dateKey ? firstReply.future : secondReply.future;
    });
    await selectDay(tester, nextDate);
    expect(requested, [dateKey, nextKey]);

    secondReply.complete(const BossSessionResult(BossSessionStatus.ok, 7.25));
    await tester.pumpAndSettle();
    expect(reportedText(tester), '7.25 小时');

    firstReply.complete(const BossSessionResult(BossSessionStatus.ok, 6.5));
    await tester.pumpAndSettle();
    expect(
      DateHelper.formatDate(
        tester.widget<WeekStrip>(find.byType(WeekStrip)).selectedDate,
      ),
      nextKey,
    );
    expect(reportedText(tester), '7.25 小时');
    expect(find.text('8.00'), findsOneWidget);
  });

  testWidgets('销毁页面移除缓存监听，晚到的查询与通知不再更新页面', (tester) async {
    final reply = Completer<BossSessionResult<double>>();
    // 本测试独立装载页面，启动前应没有残留监听。
    expect(_hasBossListeners, isFalse);
    await pumpLog(tester, (_) => reply.future);
    expect(_hasBossListeners, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(_hasBossListeners, isFalse);
    reply.complete(const BossSessionResult(BossSessionStatus.ok, 6.5));
    await tester.pumpAndSettle();
    await StorageService().saveBossHoursForDate(dateKey, 7.25);
    await tester.pumpAndSettle();

    expect(_hasBossListeners, isFalse);
    expect(tester.takeException(), isNull);
  });
}
