import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/error/exceptions.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/startup_refresh_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StartupApi extends HikiotApiClient {
  Object? accountError;
  Object? monthError;
  String? personNo = 'person-1';
  int monthCalls = 0;

  @override
  Future<Map<String, dynamic>?> getAccountDetail() async {
    if (accountError != null) throw accountError!;
    return {
      'nickName': '测试用户',
      'teamInfoList': [
        {'teamNo': 'team-1', 'teamName': '测试团队', 'personNo': personNo},
      ],
    };
  }

  @override
  Future<bool> changeTeam(String teamNo) async => true;

  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async {
    monthCalls++;
    if (monthError != null) throw monthError!;
    return {'dailyRecords': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async => null;
}

void main() {
  late _StartupApi api;
  late GlobalKey<MonthlyCalendarScreenState> key;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = _StartupApi();
    key = GlobalKey<MonthlyCalendarScreenState>();
    final now = DateTime.now();
    await StorageService().saveBossHours(
      DateHelper.formatMonth(now),
      {},
      refreshedAt: now,
    );
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MonthlyCalendarScreen(
          key: key,
          token: 'test-token',
          autoInitialize: false,
          apiClient: api,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('账户与员工信息完整后标记启动就绪', (tester) async {
    await open(tester);
    expect(key.currentState!.isUserContextReady, isFalse);

    final initialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await initialization;

    expect(key.currentState!.isUserContextReady, isTrue);
    expect(api.monthCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('再次初始化遇到过期后清除旧就绪状态，并保留重新登录入口', (tester) async {
    await open(tester);
    final firstInitialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await firstInitialization;

    api.accountError = const TokenExpiredException('登录状态已失效');
    final retry = key.currentState!.initializeUserContext();
    final readyWhileInitializing = key.currentState!.isUserContextReady;
    await tester.pumpAndSettle();
    expect(find.text('登录状态已失效'), findsOneWidget);
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await retry;

    expect(readyWhileInitializing, isFalse);
    expect(key.currentState!.isUserContextReady, isFalse);
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空员工编号不能视作会话初始化成功', (tester) async {
    api.personNo = '';
    await open(tester);
    final initialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await initialization;

    expect(key.currentState!.isUserContextReady, isFalse);
    expect(api.monthCalls, 0);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('初始化网络失败保留重试，重试成功恢复就绪', (tester) async {
    api.accountError = const NetworkException('网络不可用');
    await open(tester);
    final initialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await initialization;
    expect(key.currentState!.isUserContextReady, isFalse);

    api.accountError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(key.currentState!.isUserContextReady, isTrue);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月度接口发现过期也会撤销启动就绪状态', (tester) async {
    api.monthError = const TokenExpiredException('登录状态已失效');
    await open(tester);
    final initialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await initialization;

    expect(key.currentState!.isUserContextReady, isFalse);
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('过期启动点击稍后后结束整条启动刷新链', (tester) async {
    api.accountError = const TokenExpiredException('登录状态已失效');
    await open(tester);
    final events = <String>[];
    final startup = StartupRefreshCoordinator.run(
      initializeSession: key.currentState!.initializeUserContext,
      refreshDaily: () async => events.add('daily'),
      refreshMonthly: () async => events.add('monthly'),
      isMounted: () => key.currentState?.mounted == true,
      isSessionReady: () => key.currentState?.isUserContextReady == true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    await startup;

    expect(events, isEmpty);
    expect(find.text('登录状态已失效'), findsNothing);
    expect(find.text('重新登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
