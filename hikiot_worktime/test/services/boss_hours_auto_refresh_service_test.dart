import 'dart:convert';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('失效的旧单日查询不能把无缓存日期伪装为确认零工时', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    final gate = Completer<BossSessionResult<double>>();
    final service = BossHoursAutoRefreshService(
      storage: storage,
      loadDay: (_) => gate.future,
    );
    final pending = service.refreshDate(DateTime(2026, 9, 12));
    await storage.markBossHoursDateChanged('2026-09-12');
    gate.complete(const BossSessionResult(BossSessionStatus.ok, 0));
    expect((await pending).status, BossSessionStatus.failed);
    expect(await storage.hasBossHoursForDate('2026-09-12'), isFalse);
  });
  final now = DateTime(2026, 9, 4, 9);
  final month = DateTime(2026, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('旧版新鲜空月时间戳不能跳过严格重查', () async {
    SharedPreferences.setMockInitialValues({
      StorageKeys.bossHoursKey('2026-09'): jsonEncode({}),
      StorageKeys.bossHoursRefreshedAtKey('2026-09'): now.toIso8601String(),
    });
    var loadCount = 0;
    final storage = StorageService();
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        loadCount++;
        return {'2026-09-03': 8};
      },
    );
    expect(
      (await service.refreshIfStale(month)).status,
      BossHoursAutoRefreshStatus.updated,
    );
    expect(loadCount, 1);
    expect(
      await storage.hasFreshBossHoursForDate('2026-09-03', now: now),
      isTrue,
    );
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
  test('单日并发合并，强制刷新等待旧的 0 回包再查询提交后的新值', () async {
    final old = Completer<BossSessionResult<double>>();
    var count = 0;
    final service = BossHoursAutoRefreshService(
      loadDay: (_) {
        count++;
        return count == 1
            ? old.future
            : Future.value(const BossSessionResult(BossSessionStatus.ok, 8));
      },
    );
    final date = DateTime(2026, 9, 12);
    final first = service.refreshDate(date);
    expect(identical(first, service.refreshDate(date)), isTrue);
    final forced = service.refreshDate(date, force: true);
    expect(count, 1);
    old.complete(const BossSessionResult(BossSessionStatus.ok, 0));
    expect((await first).value, 0);
    expect((await forced).value, 8);
    expect(count, 2);
    expect((await StorageService().loadBossHours('2026-09'))['2026-09-12'], 8);
  });

  test('单日旧回包不会覆盖期间提交，返回最终缓存值', () async {
    final pending = Completer<BossSessionResult<double>>();
    final storage = StorageService();
    final service = BossHoursAutoRefreshService(
      storage: storage,
      loadDay: (_) => pending.future,
    );
    final request = service.refreshDate(DateTime(2026, 9, 12));
    await storage.saveBossHoursForDate('2026-09-12', 8);
    pending.complete(const BossSessionResult(BossSessionStatus.ok, 0));
    expect((await request).value, 8);
  });

  test('单日查询异常或无效数值不清空原缓存', () async {
    final storage = StorageService();
    await storage.saveBossHoursForDate('2026-09-12', 8);
    for (final value in [null, -1.0, double.nan, double.infinity]) {
      final service = BossHoursAutoRefreshService(
        storage: storage,
        loadDay: (_) async => BossSessionResult(BossSessionStatus.ok, value),
      );
      expect(
        (await service.refreshDate(DateTime(2026, 9, 12))).status,
        BossSessionStatus.failed,
      );
      expect((await storage.loadBossHours('2026-09'))['2026-09-12'], 8);
    }
    final service = BossHoursAutoRefreshService(
      storage: storage,
      loadDay: (_) async => throw StateError('offline'),
    );
    expect(
      (await service.refreshDate(DateTime(2026, 9, 12))).status,
      BossSessionStatus.failed,
    );
    expect((await storage.loadBossHours('2026-09'))['2026-09-12'], 8);
  });

  test('月份刷新期间单日提交的新值保留，结果与缓存一致', () async {
    final pending = Completer<Map<String, double>?>();
    final started = Completer<void>();
    final storage = StorageService();
    final service = BossHoursAutoRefreshService(
      storage: storage,
      loadMonth: (_) {
        started.complete();
        return pending.future;
      },
    );
    final request = service.refreshIfStale(month, force: true);
    await started.future;
    await storage.saveBossHoursForDate('2026-09-12', 8);
    pending.complete({'2026-09-12': 0});
    expect((await request).hours['2026-09-12'], 8);
    expect((await storage.loadBossHours('2026-09'))['2026-09-12'], 8);
  });
}
