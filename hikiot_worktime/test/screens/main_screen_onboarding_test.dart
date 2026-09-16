import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/error/exceptions.dart';
import 'package:hikiot_worktime/screens/main_screen.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/screens/settings_screen.dart';
import 'package:hikiot_worktime/services/daily_attendance_repository.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/widgets/pull_refresh_guide.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StartupApi extends HikiotApiClient {
  Completer<void>? accountGate;
  Object? accountError;
  int accountCalls = 0;

  @override
  Future<Map<String, dynamic>?> getAccountDetail() async {
    accountCalls++;
    await accountGate?.future;
    if (accountError != null) throw accountError!;
    return {
      'nickName': '测试用户',
      'teamInfoList': [
        {'teamNo': 'test-team', 'teamName': '测试团队', 'personNo': 'test-person'},
      ],
    };
  }

  @override
  Future<bool> changeTeam(String teamNo) async => true;

  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async => {'dailyRecords': <dynamic>[]};

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async => null;
}

class _DailyAttendance extends DailyAttendanceRepository {
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<DailyAttendanceLoadResult> load(
    DateTime date, {
    DateTime? workDate,
  }) async {
    calls++;
    await gate?.future;
    return const DailyAttendanceLoadResult(
      status: DailyAttendanceLoadStatus.loaded,
      teamNo: 'test-team',
      holidayPlan: {},
      dayData: {'type': '工作日', 'hours': 8.0},
      attendanceData: {'hours': 8.0},
      pinnedTarget: null,
      baseTarget: 120,
      minTarget: 100,
    );
  }
}

void main() {
  late _StartupApi api;
  late _DailyAttendance attendance;
  final storage = StorageService();

  setUp(() async {
    // 不存真实 token，日志页只能读取本地；主框架的考勤请求全部走假依赖。
    SharedPreferences.setMockInitialValues({});
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.ios();
    await HapticUtils.setMode(HapticMode.off);
    final now = DateTime.now();
    await storage.saveBossHours(
      DateHelper.formatMonth(now),
      {},
      refreshedAt: now,
    );
    api = _StartupApi();
    attendance = _DailyAttendance();
  });

  tearDown(() => PlatformCapabilities.debugOverride = null);

  // 引导动画持续播放，限量推进异步回调，避免 pumpAndSettle 等待无限动画。
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: MainScreen(
          token: 'test-token',
          apiClient: api,
          dailyRepository: attendance,
        ),
      ),
    );
    await flush(tester);
  }

  int selectedTab(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack).first).index!;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets('首次初始化失败后月度重试成功，设置重放会激活首页引导', (tester) async {
    await storage.saveOnboardingCompleted(true);
    api.accountError = const NetworkException('网络不可用');
    await open(tester);
    expect(selectedTab(tester), 1);
    expect(find.text('重试'), findsOneWidget);
    expect(attendance.calls, 0);

    api.accountError = null;
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(api.accountCalls, 2);
    expect(
      tester
          .state<MonthlyCalendarScreenState>(find.byType(MonthlyCalendarScreen))
          .isUserContextReady,
      isTrue,
    );

    await tester.tap(find.text('我的'));
    await flush(tester);
    expect(selectedTab(tester), 3);
    await tester.scrollUntilVisible(
      find.text('重新体验新手引导'),
      500,
      scrollable: find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('重新体验新手引导'));
    await flush(tester);

    expect(selectedTab(tester), 0);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    expect(attendance.calls, 1);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    expect(find.byType(Dialog), findsNothing);
    await dispose(tester);
  });

  testWidgets('初始化等待期间切到设置，迟到失败不会强制切回月度', (tester) async {
    final gate = Completer<void>();
    api.accountGate = gate;
    await open(tester);
    expect(api.accountCalls, 1);
    expect(find.byType(PullRefreshGuide), findsNothing);

    await tester.tap(find.text('我的'));
    await flush(tester);
    expect(selectedTab(tester), 3);

    api.accountError = const NetworkException('网络不可用');
    gate.complete();
    await flush(tester);

    expect(selectedTab(tester), 3);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.byType(PullRefreshGuide), findsNothing);
    expect(attendance.calls, 0);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    await dispose(tester);
  });

  testWidgets('首次首页引导等待账户与每日数据加载成功，自动刷新不算完成', (tester) async {
    final gate = Completer<void>();
    api.accountGate = gate;
    final attendanceGate = Completer<void>();
    attendance.gate = attendanceGate;
    await open(tester);

    expect(selectedTab(tester), 0);
    expect(api.accountCalls, 1);
    expect(attendance.calls, 0);
    expect(find.byType(PullRefreshGuide), findsNothing);

    gate.complete();
    await flush(tester);

    expect(attendance.calls, 1);
    expect(find.byType(PullRefreshGuide), findsNothing);
    attendanceGate.complete();
    await flush(tester);

    expect(selectedTab(tester), 0);
    expect(attendance.calls, 1);
    expect(find.byType(PullRefreshGuide), findsOneWidget);
    expect(await storage.loadOnboardingCompleted(), isFalse);
    expect(find.text('🎉 恭喜！'), findsNothing);
    await dispose(tester);
  });
}
