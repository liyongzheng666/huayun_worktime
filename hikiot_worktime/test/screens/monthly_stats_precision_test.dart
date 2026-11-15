import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只替换接口响应，保留月度仓储、分类累计和真实页面格式化。
class _MonthlyPrecisionApi extends HikiotApiClient {
  final loadedMonths = <String>[];

  @override
  Future<Map<String, dynamic>?> getAccountDetail() async => {
    'nickName': '测试用户',
    'teamInfoList': [
      {'teamNo': 'precision-team', 'teamName': '测试团队', 'personNo': 'person'},
    ],
  };

  @override
  Future<bool> changeTeam(String teamNo) async => true;

  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async {
    loadedMonths.add(month);
    return {
      'dailyRecords': [
        for (var day = 1; day <= 3; day++)
          {
            'date': '$month-${day.toString().padLeft(2, '0')}',
            'hours': 10.20,
            'checkIn': '08:00',
            'checkOut': '19:12',
            'isRestDay': false,
            'dataSourceStatus': 'apiConfirmed',
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async => null;
}

void main() {
  testWidgets('真实月度页面三个10.20累计显示30.60，不能显示30.59', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await HapticUtils.setMode(HapticMode.off);
    final now = DateTime.now();
    // 选完整历史月份，避免测试在每月1、2日运行时将样例误当未来日期。
    final selected = DateTime(now.year, now.month - 1);
    final storage = StorageService();
    for (final month in [now, selected]) {
      await storage.saveBossHours(
        DateHelper.formatMonth(month),
        {},
        refreshedAt: now,
      );
    }
    final api = _MonthlyPrecisionApi();
    final key = GlobalKey<MonthlyCalendarScreenState>();
    final boss = BossHoursAutoRefreshService(loadMonth: (_) async => {});
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MonthlyCalendarScreen(
          key: key,
          token: 'test-token',
          autoInitialize: false,
          apiClient: api,
          bossAutoRefresh: boss,
        ),
      ),
    );
    await tester.pump();
    final initialization = key.currentState!.initializeUserContext();
    await tester.pumpAndSettle();
    await initialization;

    final monthLabel = '${now.year}年${now.month.toString().padLeft(2, '0')}月';
    await tester.tap(find.text(monthLabel));
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButton<int>>(find.byType(DropdownButton<int>).at(0))
        .onChanged!(selected.year);
    await tester.pump();
    tester
        .widget<DropdownButton<int>>(find.byType(DropdownButton<int>).at(1))
        .onChanged!(selected.month);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(api.loadedMonths, contains(DateHelper.formatMonth(selected)));
    await tester.ensureVisible(find.text('总工时'));
    await tester.pumpAndSettle();
    expect(find.text('30.60'), findsOneWidget);
    expect(find.textContaining('30.59'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
