import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_hours_auto_refresh_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StorageService storage;
  final date = DateTime(2026, 9, 4);
  final now = DateTime(2026, 9, 4, 18);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'test-team', personNo: 'test-person');
  });

  test('同一轮10个强制请求只排一个旧查询后的新核对，不形成11次串行查询', () async {
    final pending = Completer<BossSessionResult<double>>();
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadDay: (_) {
        requests++;
        return requests == 1
            ? pending.future
            : Future.value(const BossSessionResult(BossSessionStatus.ok, 8));
      },
    );
    final initial = service.refreshDate(date);
    final forced = List.generate(
      10,
      (_) => service.refreshDate(date, force: true),
    );
    pending.complete(const BossSessionResult(BossSessionStatus.ok, 0));
    await initial;
    final results = await Future.wait(forced);

    expect(requests, 2);
    expect(results.map((result) => result.value), everyElement(8));
  });

  test('同身份同日10次非强制连续刷新复用已确认结果，提交前force仍查询', () async {
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadDay: (_) async {
        requests++;
        return const BossSessionResult(BossSessionStatus.ok, 8);
      },
    );
    for (var i = 0; i < 10; i++) {
      expect((await service.refreshDate(date)).value, 8);
    }
    expect(requests, 1);
    await service.refreshDate(date, force: true);
    expect(requests, 2);
  });

  test('已在查询整月时被动单日读取等待该月结果，不另开单日请求', () async {
    final pending = Completer<Map<String, double>?>();
    final started = Completer<void>();
    var dayRequests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) {
        started.complete();
        return pending.future;
      },
      loadDay: (_) async {
        dayRequests++;
        return const BossSessionResult(BossSessionStatus.ok, 8);
      },
    );
    final monthly = service.refreshIfStale(date, force: true);
    await started.future;
    final daily = service.refreshDate(date);
    pending.complete({'2026-09-04': 8});
    await monthly;
    expect((await daily).value, 8);
    expect(dayRequests, 0);
  });

  test('失败退避不跨主账号，同月新身份必须重新查询', () async {
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        requests++;
        return null;
      },
    );
    await service.refreshIfStale(date);
    await storage.saveToken('test-token-new');
    await storage.saveTeamContext(
      teamNo: 'other-team',
      personNo: 'other-person',
    );
    await service.refreshIfStale(date);
    expect(requests, 2);
  });

  test('旧身份同日请求未结束时，新身份不会合并旧请求或接收旧数据', () async {
    final pending = Completer<BossSessionResult<double>>();
    final started = Completer<void>();
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadDay: (_) {
        requests++;
        if (requests == 1) {
          started.complete();
          return pending.future;
        }
        return Future.value(const BossSessionResult(BossSessionStatus.ok, 12));
      },
    );
    final previous = service.refreshDate(date);
    await started.future;
    await storage.saveToken('test-token-new');
    await storage.saveTeamContext(
      teamNo: 'other-team',
      personNo: 'other-person',
    );
    final current = service.refreshDate(date);
    pending.complete(const BossSessionResult(BossSessionStatus.ok, 8));
    final oldResult = await previous;
    final newResult = await current;
    expect(requests, 2);
    expect(oldResult.isOk, isFalse);
    expect(newResult.value, 12);
    expect((await storage.loadBossHours('2026-09'))['2026-09-04'], 12);
  });

  test('重建模块后同scope的owned月和短窗日证明零网络复用，新scope重新核对', () async {
    var monthRequests = 0;
    var dayRequests = 0;
    BossHoursAutoRefreshService create() => BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        monthRequests++;
        return {'2026-09-04': 8};
      },
      loadDay: (_) async {
        dayRequests++;
        return const BossSessionResult(BossSessionStatus.ok, 8);
      },
    );
    await create().refreshIfStale(date, force: true);
    final rebuilt = create();
    expect(
      (await rebuilt.refreshIfStale(date)).status,
      BossHoursAutoRefreshStatus.fresh,
    );
    expect((await rebuilt.refreshDate(date)).value, 8);
    expect(monthRequests, 1);
    expect(dayRequests, 0);

    await storage.saveToken('test-new-token');
    await storage.saveTeamContext(teamNo: 'new-team', personNo: 'new-person');
    expect(
      (await rebuilt.refreshIfStale(date)).status,
      BossHoursAutoRefreshStatus.updated,
    );
    expect(monthRequests, 2);
  });

  test('已确认月份仅一天owner失效时只补这一天，不重查整月', () async {
    var monthRequests = 0;
    var dayRequests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) async {
        monthRequests++;
        return {'2026-09-04': 8};
      },
      loadDay: (_) async {
        dayRequests++;
        return const BossSessionResult(BossSessionStatus.ok, 9);
      },
    );
    await service.refreshIfStale(date, force: true);
    await storage.markBossHoursDateChanged('2026-09-04');
    await storage.saveBossHoursForDate('2026-09-04', 9, refreshedAt: now);
    final result = await service.refreshIfStale(date);
    expect(result.hours['2026-09-04'], 9);
    expect(monthRequests, 1);
    expect(dayRequests, 1);
  });

  test('单日失败退避按日期隔离，force和过期均重新查询，旧成功不掩盖新失败', () async {
    var clock = now;
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => clock,
      loadDay: (_) async {
        requests++;
        return requests == 1
            ? const BossSessionResult(BossSessionStatus.ok, 8)
            : const BossSessionResult(BossSessionStatus.failed);
      },
    );
    expect((await service.refreshDate(date)).value, 8);
    expect((await service.refreshDate(date, force: true)).isOk, isFalse);
    expect((await service.refreshDate(date)).isOk, isFalse);
    expect(requests, 2);
    await service.refreshDate(date.add(const Duration(days: 1)));
    expect(requests, 3);
    await service.refreshDate(date, force: true);
    expect(requests, 4);
    clock = clock.add(const Duration(minutes: 6));
    await service.refreshDate(date);
    expect(requests, 5);
  });

  test('day短窗到期或date变更必须查询，force不受新鲜证明影响', () async {
    var clock = now;
    var requests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => clock,
      loadDay: (_) async {
        requests++;
        return const BossSessionResult(BossSessionStatus.ok, 8);
      },
    );
    await service.refreshDate(date);
    await service.refreshDate(date);
    expect(requests, 1);
    clock = clock.add(const Duration(seconds: 30));
    await service.refreshDate(date);
    expect(requests, 2);
    await storage.markBossHoursDateChanged('2026-09-04');
    await service.refreshDate(date);
    expect(requests, 3);
    await service.refreshDate(date, force: true);
    expect(requests, 4);
  });

  test('月查询中的force单日核对仍远端读取且旧月回包不覆盖新日值', () async {
    final pending = Completer<Map<String, double>?>();
    final started = Completer<void>();
    var dayRequests = 0;
    final service = BossHoursAutoRefreshService(
      storage: storage,
      now: () => now,
      loadMonth: (_) {
        started.complete();
        return pending.future;
      },
      loadDay: (_) async {
        dayRequests++;
        return const BossSessionResult(BossSessionStatus.ok, 12);
      },
    );
    final monthly = service.refreshIfStale(date, force: true);
    await started.future;
    expect((await service.refreshDate(date, force: true)).value, 12);
    expect(dayRequests, 1);
    pending.complete({'2026-09-04': 8});
    expect((await monthly).hours['2026-09-04'], 12);
    expect((await storage.loadBossHours('2026-09'))['2026-09-04'], 12);
  });
}
