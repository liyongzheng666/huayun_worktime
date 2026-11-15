import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/screens/work_log_screen.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends HikiotApiClient {
  @override
  Future<Map<String, dynamic>?> getAccountDetail() async => {
    'teamInfoList': [
      {'teamNo': 'test-team', 'teamName': '测试团队', 'personNo': 'person'},
    ],
  };
  @override
  Future<bool> changeTeam(String teamNo) async => true;
  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async => {
    'dailyRecords': [
      {
        'date': '$month-01',
        'hours': 8.0,
        'checkIn': '09:00',
        'checkOut': '18:00',
        'isRestDay': false,
        'dataSourceStatus': 'apiConfirmed',
      },
    ],
  };
  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async => null;
}

class _UnusedWebView implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 仅网页响应使用替身，提交后回读、存储通知与两个页面使用真实实现。
class _Submit extends WorkLogSubmitService {
  _Submit() : super(_UnusedWebView());
  int writes = 0;
  final reads = <String>[];
  @override
  Future<String?> runScript(String script, {bool logResult = true}) async {
    writes++;
    return '{"ok":true,"objectId":"WORKLOG_saved"}';
  }

  @override
  Future<double?> queryExistingHours(String date) async {
    reads.add(date);
    return 7.25;
  }
}

void main() {
  final storage = StorageService();
  late String month;
  late String date;
  late GlobalKey<MonthlyCalendarScreenState> screenKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await HapticUtils.setMode(HapticMode.off);
    month = DateHelper.formatMonth(DateTime.now());
    date = '$month-01';
    screenKey = GlobalKey<MonthlyCalendarScreenState>();
    await storage.saveBossHours(month, {date: 6.5});
  });
  tearDown(() => PlatformCapabilities.debugOverride = null);

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MonthlyCalendarScreen(
          key: screenKey,
          token: 'test',
          apiClient: _Api(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> detail(WidgetTester tester) async {
    final cell = find.descendant(
      of: find.byType(GridView),
      matching: find.text('1'),
    );
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();
  }

  testWidgets('安卓其他页面更新日报合计后，月历无需网络或手动刷新即可读到新值', (tester) async {
    await open(tester);
    await storage.saveBossHoursForDate(date, 7.25);
    await tester.pumpAndSettle();
    await detail(tester);
    expect(find.textContaining('BOSS 已填 7.25h'), findsOneWidget);
    expect(find.textContaining('BOSS 已填 6.50h'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月度明细打开时日报合计变化也立即更新，不用关掉重进', (tester) async {
    await open(tester);
    await detail(tester);
    expect(find.textContaining('BOSS 已填 6.50h'), findsOneWidget);
    await storage.saveBossHoursForDate(date, 7.25);
    await tester.pumpAndSettle();
    expect(find.textContaining('BOSS 已填 7.25h'), findsOneWidget);
    expect(find.textContaining('BOSS 已填 6.50h'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('整月缓存仍新鲜时切回月度页也必须采用新日报合计', (tester) async {
    await open(tester);
    await storage.saveBossHours(month, {date: 7.25});
    await screenKey.currentState!.refreshFromStorage();
    await tester.pumpAndSettle();
    await detail(tester);
    expect(find.textContaining('BOSS 已填 7.25h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存后合计尚未确认时保留上次值并标明待确认', (tester) async {
    await open(tester);
    await detail(tester);
    await storage.markBossHoursDateChanged(date);
    await tester.pumpAndSettle();
    expect(find.text('上次 BOSS 已填 6.50h，当前待确认'), findsOneWidget);
  });

  testWidgets('服务端确认零工时后明细不能残留旧的正数', (tester) async {
    await open(tester);
    await detail(tester);
    await storage.saveBossHoursForDate(date, 0);
    await tester.pumpAndSettle();
    expect(find.textContaining('BOSS 已填 0.00h'), findsOneWidget);
    expect(find.textContaining('BOSS 已填 6.50h'), findsNothing);
  });

  testWidgets('安卓一次真实提交编排贯通缓存、日志时长和月度明细，保持打卡工时独立', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var dayQueries = 0;
    var monthQueries = 0;
    final refresh = BossHoursAutoRefreshService(
      loadDay: (_) async {
        dayQueries++;
        return const BossSessionResult(BossSessionStatus.ok, 6.5);
      },
      loadMonth: (_) async {
        monthQueries++;
        return null;
      },
    );
    final logKey = GlobalKey<WorkLogScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: IndexedStack(
          children: [
            MonthlyCalendarScreen(
              key: screenKey,
              token: 'test',
              apiClient: _Api(),
              bossAutoRefresh: refresh,
            ),
            WorkLogScreen(
              key: logKey,
              bossAutoRefresh: refresh,
              repository: WorkLogRepository(
                loadWorkHours: (_) async => const WorkLogHours(hours: 8),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await logKey.currentState!.handleWrapUpAction(
      DateTime.parse(date),
      TodayWrapUpAction.checkAttendance,
    );
    await tester.pumpAndSettle();
    final queriesBefore = (dayQueries, monthQueries);
    final service = _Submit();
    final result = await service.submit(
      entry: WorkLogEntry(
        date: date,
        projectName: '测试项目',
        workType: '研发',
        stage: '无',
        activity: '无',
        title: '测试日报',
        content: '测试内容',
      ),
      actWork: '8.00',
      constants: const {'projectId': 'PROJECT_test', 'auditor': 'USER_test'},
    );
    await tester.pumpAndSettle();
    expect(result.status, WorkLogSubmitStatus.submitted);
    expect(service.writes, 1);
    expect(service.reads, [date]);
    expect((dayQueries, monthQueries), queriesBefore);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('reported-boss-hours'),
              skipOffstage: false,
            ),
          )
          .data,
      '7.25 小时',
    );
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('打卡工时', skipOffstage: false),
              matching: find.byType(Column, skipOffstage: false),
            )
            .first,
        matching: find.text('8.00', skipOffstage: false),
      ),
      findsOneWidget,
    );
    await detail(tester);
    expect(find.textContaining('BOSS 已填 7.25h'), findsOneWidget);
    expect((await storage.loadBossHours(month))[date], 7.25);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await storage.saveBossHoursForDate(date, 9);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
