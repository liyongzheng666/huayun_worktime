import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SyncApi extends HikiotApiClient {
  int monthCalls = 0;
  final dailyCalls = <String>[];

  @override
  Future<Map<String, dynamic>?> getAccountDetail() async => {
    'teamInfoList': [
      {'teamNo': 'team-sync', 'teamName': '测试团队', 'personNo': 'person-sync'},
    ],
  };

  @override
  Future<bool> changeTeam(String teamNo) async => true;

  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async {
    monthCalls++;
    return {'dailyRecords': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async {
    dailyCalls.add(date);
    return {
      'dailyDetail': {'shiftId': -1, 'shiftDetails': <dynamic>[]},
    };
  }
}

void main() {
  late _SyncApi api;
  late BossHoursAutoRefreshService boss;
  late Completer<BossSessionResult<Map<String, double>>> bossResponse;
  late int bossCalls;
  late ValueNotifier<bool> active;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HapticUtils.setMode(HapticMode.off);
    api = _SyncApi();
    bossCalls = 0;
    final storage = StorageService();
    await storage.saveToken('test');
    await storage.saveTeamContext(teamNo: 'team-sync', personNo: 'person-sync');
    await storage.saveBossHours(
      DateHelper.formatMonth(DateTime.now()),
      {},
      expectedAuthRevision: await storage.loadAuthRevision(),
      expectedScope: await storage.loadBossCredentialScope(),
    );
  });

  Future<void> open(WidgetTester tester) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    bossResponse = Completer<BossSessionResult<Map<String, double>>>();
    boss = BossHoursAutoRefreshService(
      loadMonthResult: (_) {
        bossCalls++;
        return bossResponse.future;
      },
    );
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, value, _) => MonthlyCalendarScreen(
            token: 'test',
            apiClient: api,
            bossAutoRefresh: boss,
            isActive: value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.monthCalls, 1);
  }

  testWidgets('全量考勤完成后华天仍在同步时保留忙碌状态，不能再发整月考勤请求', (tester) async {
    await open(tester);
    await tester.tap(find.text('全量更新工时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(bossCalls, 1);
    final button = find.text('全量更新工时');
    if (button.evaluate().isNotEmpty) {
      await tester.tap(button);
      await tester.pump();
    }
    expect(api.monthCalls, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('全量更新完成'), findsNothing);

    bossResponse.complete(const BossSessionResult(BossSessionStatus.ok, {}));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全量同步与同月后台华天查询重叠时复用同一任务', (tester) async {
    await open(tester);
    final background = boss.refreshIfStale(DateTime.now(), force: true);
    await tester.pump();
    expect(bossCalls, 1);
    await tester.tap(find.text('全量更新工时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(api.monthCalls, 2);
    expect(bossCalls, 1);

    bossResponse.complete(const BossSessionResult(BossSessionStatus.ok, {}));
    await background;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉只走考勤快速更新，不额外全量查询考勤或华天', (tester) async {
    await open(tester);
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 450));
    await tester.pumpAndSettle();
    expect(api.dailyCalls, isNotEmpty);
    expect(api.monthCalls, 1);
    expect(bossCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步期间切走月度页，未登录回包不在隐藏页弹登录框', (tester) async {
    await open(tester);
    await tester.tap(find.text('全量更新工时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    active.value = false;
    await tester.pump();
    bossResponse.complete(const BossSessionResult(BossSessionStatus.noSession));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('华天同步失败保留旧已填数据并结束忙碌，不提示整项同步完成', (tester) async {
    final day = '${DateHelper.formatMonth(DateTime.now())}-01';
    final storage = StorageService();
    await storage.saveBossHoursForDate(
      day,
      10.2,
      expectedAuthRevision: await storage.loadAuthRevision(),
      expectedScope: await storage.loadBossCredentialScope(),
    );
    await open(tester);
    await tester.tap(find.text('全量更新工时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    bossResponse.complete(const BossSessionResult(BossSessionStatus.failed));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('考勤与华天同步完成'), findsNothing);
    expect(
      (await StorageService().loadBossHours(day.substring(0, 7)))[day],
      10.2,
    );
    expect(tester.takeException(), isNull);
  });
}
