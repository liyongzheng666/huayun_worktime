import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 集成测试保留真实缓存、月度适配与算法，只替换网页响应。
class MonthlyBalanceFixture {
  final storage = StorageService();
  DateTime now = DateTime(2026, 9, 3, 19);
  late final service = MonthlyReportBalanceService(
    storage: storage,
    clock: () => now,
  );

  Future<void> seed({List<double> hours = const [10.42, 10.37, 10.41]}) async {
    SharedPreferences.setMockInitialValues({});
    await storage.saveTeamContext(teamNo: 'test-team');
    await storage.saveMonthlyData('test-team', '2026-09', {
      for (var day = 1; day <= 3; day++)
        '2026-09-${day.toString().padLeft(2, '0')}': {
          'hours': day <= hours.length ? hours[day - 1] : 0.0,
          'type': '工作日',
          'dataSourceStatus': 'apiConfirmed',
          'checkIn': '08:00',
          'checkOut': '19:00',
        },
    });
    await storage.saveMonthlyHoursCalculationVersion('test-team', '2026-09');
    await storage.saveBossHours('2026-09', {}, refreshedAt: now);
  }
}
