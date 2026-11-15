import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/screens/daily_hours_screen.dart';
import 'package:hikiot_worktime/screens/feature_guide_page.dart';
import 'package:hikiot_worktime/services/daily_attendance_repository.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/today_wrap_up_service.dart';
import 'package:hikiot_worktime/widgets/haptic_refresh_indicator.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/widgets/pull_refresh_guide.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Attendance extends DailyAttendanceRepository {
  Object? error;
  int calls = 0;
  Completer<void>? pending;
  DailyAttendanceLoadStatus status = DailyAttendanceLoadStatus.loaded;
  bool hasAttendance = true;

  @override
  Future<DailyAttendanceLoadResult> load(
    DateTime date, {
    DateTime? workDate,
  }) async {
    calls++;
    await pending?.future;
    if (error != null) throw error!;
    return DailyAttendanceLoadResult(
      status: status,
      teamNo: 'team',
      holidayPlan: const {},
      dayData: const {'type': '工作日', 'hours': 8.0},
      attendanceData: hasAttendance ? const {'hours': 8.0} : null,
      pinnedTarget: null,
      baseTarget: 120,
      minTarget: 100,
    );
  }
}

class _WrapUp extends TodayWrapUpService {
  @override
  Future<TodayWrapUpData> loadCached(DateTime date) async =>
      TodayWrapUpData(date: date);
  @override
  Future<TodayWrapUpData> load(DateTime date) => loadCached(date);
}

void main() {
  late _Attendance repository;
  final storage = StorageService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.ios();
    repository = _Attendance();
    await HapticUtils.setMode(HapticMode.off);
  });
  tearDown(() => PlatformCapabilities.debugOverride = null);

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, {ValueNotifier<bool>? active}) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: PlatformCapabilities.supportsExactBackgroundAlarm
              ? TargetPlatform.android
              : TargetPlatform.iOS,
        ),
        home: ValueListenableBuilder<bool>(
          valueListenable: active ?? ValueNotifier(true),
          builder: (context, isActive, child) => DailyHoursScreen(
            isActive: isActive,
            dailyRepository: repository,
            todayWrapUpService: _WrapUp(),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets('隐藏首页在应用恢复前台时不刷新，当前首页恢复时只刷新一次', (tester) async {
    await storage.saveOnboardingCompleted(true);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await open(tester, active: active);
    expect(repository.calls, 1);

    active.value = false;
    await flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(repository.calls, 1);

    active.value = true;
    await flush(tester);
    expect(repository.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(repository.calls, 2);
    await dispose(tester);
  });

  testWidgets('iOS 真正下拉后结束引导并保存完成状态', (tester) async {
    await open(tester);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    await tester.dragFrom(const Offset(80, 250), const Offset(0, 550));
    await flush(tester);
    expect(repository.calls, 2);
    expect(find.byType(PullRefreshGuide), findsNothing);
    expect(await storage.loadOnboardingCompleted(), isTrue);
    expect(find.text('🎉 恭喜！'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('跳过只关闭引导，不误报已掌握手势或强制再弹窗', (tester) async {
    await open(tester);
    await tester.tap(find.text('我知道了'));
    await flush(tester);
    expect(find.byType(PullRefreshGuide), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(await storage.loadOnboardingCompleted(), isTrue);
    await dispose(tester);
  });

  testWidgets('Android 下拉失败后自动刷新不能误完成引导', (tester) async {
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await open(tester);
    repository.error = StateError('offline');
    await tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await flush(tester);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    repository.error = null;
    await tester
        .state<DailyHoursScreenState>(find.byType(DailyHoursScreen))
        .refreshData();
    await flush(tester);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    await dispose(tester);
  });

  testWidgets('资料缺失和无服务端结果不能误报刷新引导成功', (tester) async {
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await open(tester);
    repository.status = DailyAttendanceLoadStatus.missingPersonNo;
    repository.hasAttendance = false;
    await tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await flush(tester);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    await dispose(tester);
  });

  testWidgets('已完成不再自动展示，未完成重新进入仍可学习', (tester) async {
    await open(tester);
    await dispose(tester);
    await open(tester);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    await tester.tap(find.text('我知道了'));
    await flush(tester);
    await dispose(tester);
    await open(tester);
    expect(find.byType(PullRefreshGuide), findsNothing);
    await dispose(tester);
  });

  testWidgets('下拉等待期间切页不在其它页弹完成框，返回后仍可引导', (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await open(tester, active: active);
    final pending = Completer<void>();
    repository.pending = pending;
    final refresh = tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await tester.pump();
    active.value = false;
    await tester.pump();
    pending.complete();
    await refresh;
    await flush(tester);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(PullRefreshGuide), findsNothing);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    active.value = true;
    await flush(tester);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('下拉途中打开其它弹窗，迟到刷新不覆盖当前对话框', (tester) async {
    await open(tester);
    final pending = Completer<void>();
    repository.pending = pending;
    final refresh = tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(DailyHoursScreen)),
        builder: (_) => const AlertDialog(content: Text('核对资料')),
      ),
    );
    await tester.pump();
    pending.complete();
    await refresh;
    await flush(tester);
    expect(find.text('核对资料'), findsOneWidget);
    expect(find.text('🎉 恭喜！'), findsNothing);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    await dispose(tester);
  });

  testWidgets('下拉等待时连续点击跳过不会重复完成或迟到弹窗', (tester) async {
    await open(tester);
    final pending = Completer<void>();
    repository.pending = pending;
    final refresh = tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    final complete = tester
        .widget<PullRefreshGuide>(find.byType(PullRefreshGuide))
        .onCompleted;
    complete();
    complete();
    await flush(tester);
    pending.complete();
    await refresh;
    await flush(tester);
    expect(await storage.loadOnboardingCompleted(), isTrue);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(PullRefreshGuide), findsNothing);
    await dispose(tester);
  });

  testWidgets('成功后打开功能说明并关闭，返回首页且不再弹引导', (tester) async {
    await open(tester);
    await tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await flush(tester);
    await tester.tap(find.text('查看功能说明'));
    await flush(tester);
    expect(find.byType(FeatureGuidePage), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await flush(tester);
    expect(find.byType(DailyHoursScreen), findsOneWidget);
    expect(find.byType(PullRefreshGuide), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    await dispose(tester);
  });

  testWidgets('页面销毁后延迟检查及刷新返回不更新已销毁状态', (tester) async {
    repository.pending = Completer<void>();
    await open(tester);
    await dispose(tester);
    repository.pending!.complete();
    await flush(tester);
    expect(tester.takeException(), isNull);
    expect(await storage.loadOnboardingCompleted(), isFalse);
  });

  testWidgets('完成弹窗连续查看功能说明不会多弹页面或移除首页', (tester) async {
    await open(tester);
    await tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await flush(tester);
    final continueAction = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '查看功能说明'))
        .onPressed!;
    continueAction();
    continueAction();
    await flush(tester);
    expect(find.byType(FeatureGuidePage), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await flush(tester);
    expect(find.byType(DailyHoursScreen), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await dispose(tester);
  });

  testWidgets('完成提示横屏仍可查看内容和稍后关闭', (tester) async {
    await open(tester);
    await tester
        .widget<HapticRefreshIndicator>(find.byType(HapticRefreshIndicator))
        .onRefresh();
    await flush(tester);
    await tester.binding.setSurfaceSize(const Size(568, 320));
    await flush(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('稍后再看'));
    await tester.tap(find.text('稍后再看'));
    await flush(tester);
    expect(find.byType(Dialog), findsNothing);
    await dispose(tester);
  });
}
