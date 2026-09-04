import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 9, 4, 9);
  final month = DateTime(2026, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('15 分钟内的缓存直接使用，不启动隐藏 WebView', () async {
    final storage = StorageService();
    await storage.saveBossHours('2026-09', {
      '2026-09-03': 8,
    }, refreshedAt: now.subtract(const Duration(minutes: 5)));
    var loadCount = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        loadCount++;
        return {};
      },
    );

    final result = await service.refreshIfStale(month);

    expect(result.status, BossHoursAutoRefreshStatus.fresh);
    expect(result.hours['2026-09-03'], 8);
    expect(loadCount, 0);
  });

  test('过期后静默刷新并写回缓存与刷新时间', () async {
    final storage = StorageService();
    await storage.saveBossHours('2026-09', {
      '2026-09-03': 8,
    }, refreshedAt: now.subtract(const Duration(hours: 1)));
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async => {'2026-09-03': 9.5},
    );

    final result = await service.refreshIfStale(month);

    expect(result.status, BossHoursAutoRefreshStatus.updated);
    expect(result.hours['2026-09-03'], 9.5);
    expect((await storage.loadBossHours('2026-09'))['2026-09-03'], 9.5);
    expect(await storage.loadBossHoursRefreshedAt('2026-09'), now);
  });

  test('未登录或网络失败时保留旧缓存，也不伪造刷新时间', () async {
    final storage = StorageService();
    final old = now.subtract(const Duration(hours: 1));
    await storage.saveBossHours('2026-09', {'2026-09-03': 8}, refreshedAt: old);
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async => null,
    );

    final result = await service.refreshIfStale(month);

    expect(result.status, BossHoursAutoRefreshStatus.unavailable);
    expect(result.hours['2026-09-03'], 8);
    expect((await storage.loadBossHours('2026-09'))['2026-09-03'], 8);
    expect(await storage.loadBossHoursRefreshedAt('2026-09'), old);
  });

  test('失败后五分钟内不反复启动隐藏 WebView', () async {
    var loadCount = 0;
    final service = BossHoursAutoRefreshService(
      storage: StorageService(),
      now: () => now,
      loadMonth: (_) async {
        loadCount++;
        return null;
      },
    );

    await service.refreshIfStale(month);
    await service.refreshIfStale(month);

    expect(loadCount, 1);
  });

  test('同月并发刷新合并为一次请求', () async {
    final gate = Completer<Map<String, double>?>();
    var loadCount = 0;
    final service = BossHoursAutoRefreshService(
      storage: StorageService(),
      now: () => now,
      loadMonth: (_) {
        loadCount++;
        return gate.future;
      },
    );

    final first = service.refreshIfStale(month);
    final second = service.refreshIfStale(DateTime(2026, 9, 20));
    expect(identical(first, second), isTrue);
    gate.complete({'2026-09-03': 8});

    await Future.wait([first, second]);
    expect(loadCount, 1);
  });

  test('force 会忽略新鲜度，供用户手动刷新复用', () async {
    final storage = StorageService();
    await storage.saveBossHours('2026-09', {}, refreshedAt: now);
    var loadCount = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        loadCount++;
        return {'2026-09-04': 8};
      },
    );

    final result = await service.refreshIfStale(month, force: true);

    expect(result.status, BossHoursAutoRefreshStatus.updated);
    expect(loadCount, 1);
  });
}
