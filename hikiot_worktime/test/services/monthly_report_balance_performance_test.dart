import 'package:flutter/foundation.dart';
// 测试直接观察SharedPreferences既有插件适配器的持久化调用次数。
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _CountStore extends InMemorySharedPreferencesStore {
  _CountStore() : super.empty();
  int writes = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return super.setValue(valueType, key, value);
  }
}

class _CountStorage extends StorageService {
  int dayProofReads = 0;
  @override
  Future<bool> hasFreshBossHoursForDate(
    String date, {
    DateTime? now,
    Duration maxAge = const Duration(minutes: 15),
  }) {
    dayProofReads++;
    return super.hasFreshBossHoursForDate(date, now: now, maxAge: maxAge);
  }
}

void main() {
  test('完整月度只读核对不反复持久化已完成迁移的身份字段', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _CountStore();
    SharedPreferencesStorePlatform.instance = platform;
    final storage = _CountStorage();
    final now = DateTime(2026, 10, 31, 20);
    await storage.saveTeamContext(
      teamNo: 'fixture-team',
      personNo: 'fixture-person',
    );
    await storage.saveMonthlyData('fixture-team', '2026-10', {
      for (var day = 1; day <= 31; day++)
        '2026-10-${day.toString().padLeft(2, '0')}': {
          'hours': 10.42,
          'type': AppConstants.typeWorkday,
          'dataSourceStatus': 'apiConfirmed',
          'checkIn': '08:00',
          'checkOut': '19:00',
        },
    });
    await storage.saveMonthlyHoursCalculationVersion('fixture-team', '2026-10');
    await storage.saveBossHours('2026-10', {}, refreshedAt: now);
    platform.writes = 0;
    final service = MonthlyReportBalanceService(
      storage: storage,
      clock: () => now,
    );
    final first = await service.load(now);
    expect(first.isReady, isTrue, reason: first.unavailableReason);
    final firstWrites = platform.writes;
    final firstProofReads = storage.dayProofReads;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      expect((await service.load(now)).isReady, isTrue);
    }
    watch.stop();
    debugPrint(
      'MONTHLY_PERF writesPerLoad=$firstWrites dayProofReadsPerLoad=$firstProofReads warm100Us=${watch.elapsedMicroseconds}',
    );
    expect(firstWrites, 0, reason: '读取已有身份不应再次向原生持久化同一个值');
    expect(platform.writes, 0);
  });
  test('重复读取已规范化通用和提醒设置不再次持久化同值', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _CountStore();
    SharedPreferencesStorePlatform.instance = platform;
    final storage = StorageService();
    await storage.loadSettings();
    await storage.loadReminderSettings();
    platform.writes = 0;
    await storage.loadSettings();
    await storage.loadReminderSettings();
    debugPrint('SETTINGS_PERF repeatedReadWrites=${platform.writes}');
    expect(platform.writes, 0);
  });
}
