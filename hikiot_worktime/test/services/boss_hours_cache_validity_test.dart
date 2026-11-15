import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final storage = StorageService();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('缺失缓存未知；严格空表和十进制数值字符串可供逐日证明判断', () async {
    expect(await storage.hasValidBossHoursCache('2026-09'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.bossHoursKey('2026-09'), '{}');
    expect(await storage.hasValidBossHoursCache('2026-09'), isTrue);
    await prefs.setString(
      StorageKeys.bossHoursKey('2026-09'),
      jsonEncode({'2026-09-03': '10.20', '2026-09-30': 0}),
    );
    expect(await storage.hasValidBossHoursCache('2026-09'), isTrue);
    expect((await storage.loadBossHours('2026-09'))['2026-09-03'], 10.2);
  });

  test('非标准月份、日期与非数值原始记录不能被宽松读取器掩盖', () async {
    final prefs = await SharedPreferences.getInstance();
    for (final month in ['2026-9', '2026-00', '2026-13']) {
      await prefs.setString(StorageKeys.bossHoursKey(month), '{}');
      expect(await storage.hasValidBossHoursCache(month), isFalse);
    }
    for (final raw in [
      jsonEncode({'2026-09-3': 8}),
      jsonEncode({'2026-09-31': 8}),
      jsonEncode({'2026-10-01': 8}),
      jsonEncode({'2026-09-03': true}),
      '[]',
    ]) {
      await prefs.setString(StorageKeys.bossHoursKey('2026-09'), raw);
      expect(await storage.hasValidBossHoursCache('2026-09'), isFalse);
    }
  });
}
