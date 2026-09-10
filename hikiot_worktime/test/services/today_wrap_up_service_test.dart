import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/today_wrap_up_service.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 9, 15, 19);
  final old = now.subtract(const Duration(hours: 2));
  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  test('本地素材先显示，历史已提交不升级为本次确认', () async {
    await storage.saveBossHours('2026-09', {'2026-09-15': 8}, refreshedAt: old);
    final service = TodayWrapUpService(
      storage: storage,
      now: () => now,
      loadBossHours: (_) => throw StateError('不应查询'),
    );
    final result = await service.loadCached(now);
    expect(result.bossStatus, TodayBossStatus.unknown);
    expect(result.checkedAt, isNull);
    expect(result.cachedBossHours, 8);
    expect(result.cachedAt, old);
    expect(result.hasEntry, isFalse);
  });

  test('读取已导入的当日 CSV，其他日期素材不能冒充今天', () async {
    final repository = WorkLogRepository(storage: storage);
    await repository.importFromCsv(
      '日期,项目名称,BOSS工作类型,项目阶段,阶段活动,标题,工作内容\n'
      '2026-09-15,测试项目,研发,软件编码阶段,软件编码,测试标题,测试内容',
    );
    final service = TodayWrapUpService(
      storage: storage,
      repository: repository,
    );
    expect((await service.loadCached(now)).hasEntry, isTrue);
    expect(
      (await service.loadCached(now.add(const Duration(days: 1)))).hasEntry,
      isFalse,
    );
  });

  test('只查传入单日，0 和正数分别解析为未提交和已提交', () async {
    final queried = <String>[];
    var hours = 0.0;
    final service = TodayWrapUpService(
      storage: storage,
      now: () => now,
      loadBossHours: (date) async {
        queried.add(date);
        return BossSessionResult(BossSessionStatus.ok, hours);
      },
    );
    final zero = await service.load(now);
    expect(zero.bossStatus, TodayBossStatus.unsubmitted);
    expect(zero.checkedAt, now);
    hours = 8;
    final submitted = await service.load(now);
    expect(submitted.bossStatus, TodayBossStatus.submitted);
    expect(queried, ['2026-09-15', '2026-09-15']);
    expect(await storage.loadBossHours('2026-09'), isEmpty);
  });

  test('同日并发合并一次，后续刷新发新请求', () async {
    final gate = Completer<BossSessionResult<double>>();
    var calls = 0;
    final service = TodayWrapUpService(
      storage: storage,
      loadBossHours: (_) {
        calls++;
        return gate.future;
      },
    );
    final first = service.load(now);
    final second = service.load(now.add(const Duration(hours: 1)));
    expect(identical(first, second), isTrue);
    gate.complete(const BossSessionResult(BossSessionStatus.ok, 8));
    await Future.wait([first, second]);
    expect(calls, 1);
    await service.load(now);
    expect(calls, 2);
  });

  test('后台查询期间导入的 CSV 和更新的缓存不会被旧快照覆盖', () async {
    final started = Completer<void>();
    final gate = Completer<BossSessionResult<double>>();
    final repository = WorkLogRepository(storage: storage);
    var calls = 0;
    final service = TodayWrapUpService(
      storage: storage,
      repository: repository,
      now: () => now,
      loadBossHours: (_) {
        calls++;
        started.complete();
        return gate.future;
      },
    );
    final pending = service.load(now);
    await started.future;
    await repository.importFromCsv(
      '日期,项目名称,BOSS工作类型,项目阶段,阶段活动,标题,工作内容\n'
      '2026-09-15,测试项目,研发,软件编码阶段,软件编码,测试标题,测试内容',
    );
    await storage.saveBossHours('2026-09', {'2026-09-15': 8}, refreshedAt: now);
    expect((await service.loadCached(now)).hasEntry, isTrue);
    expect(identical(pending, service.load(now)), isTrue);
    gate.complete(const BossSessionResult(BossSessionStatus.ok, 8));

    final result = await pending;
    expect(result.hasEntry, isTrue);
    expect(result.cachedBossHours, 8);
    expect(result.cachedAt, now);
    expect(result.bossStatus, TodayBossStatus.submitted);
    expect(calls, 1);
  });

  for (final status in [
    BossSessionStatus.failed,
    BossSessionStatus.noSession,
    BossSessionStatus.ok,
  ]) {
    test('$status 无有效数值保留过期缓存，不伪造确认时间', () async {
      await storage.saveBossHours('2026-09', {
        '2026-09-15': 8,
      }, refreshedAt: old);
      final service = TodayWrapUpService(
        storage: storage,
        now: () => now,
        loadBossHours: (_) async => BossSessionResult(status),
      );
      final result = await service.load(now);
      expect(
        result.bossStatus,
        status == BossSessionStatus.noSession
            ? TodayBossStatus.noSession
            : TodayBossStatus.unknown,
      );
      expect(result.bossHours, isNull);
      expect(result.checkedAt, isNull);
      expect(result.cachedBossHours, 8);
      expect(await storage.loadBossHoursRefreshedAt('2026-09'), old);
      expect((await storage.loadBossHours('2026-09'))['2026-09-15'], 8);
    });
  }

  test('成功后的网络失败不能继续显示实时已提交', () async {
    var succeeds = true;
    final service = TodayWrapUpService(
      storage: storage,
      now: () => now,
      loadBossHours: (_) async {
        if (!succeeds) throw StateError('network');
        return const BossSessionResult(BossSessionStatus.ok, 8);
      },
    );
    expect((await service.load(now)).bossStatus, TodayBossStatus.submitted);
    succeeds = false;
    final result = await service.load(now);
    expect(result.bossStatus, TodayBossStatus.unknown);
    expect(result.checkedAt, isNull);
  });

  for (final hours in [double.nan, double.infinity, -1.0]) {
    test('无效工时 $hours 不确认状态', () async {
      final service = TodayWrapUpService(
        storage: storage,
        loadBossHours: (_) async =>
            BossSessionResult(BossSessionStatus.ok, hours),
      );
      expect((await service.load(now)).bossStatus, TodayBossStatus.unknown);
    });
  }
}
