// 仅测试平台持久化的队列时序，不接入真实账号或原生磁盘。
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _PausedStore extends InMemorySharedPreferencesStore {
  _PausedStore() : super.empty();
  String? pauseKey;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == pauseKey) {
      pauseKey = null;
      entered!.complete();
      await release!.future;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  final moment = DateTime(2026, 10, 31, 20);
  late StorageService storage;
  late _PausedStore platform;
  late String scope;
  late int authRevision;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = _PausedStore();
    SharedPreferencesStorePlatform.instance = platform;
    storage = StorageService();
    await storage.saveToken('fixture-token');
    await storage.saveTeamContext(teamNo: 'team-a', personNo: 'person-a');
    scope = (await storage.loadBossCredentialScope())!;
    authRevision = await storage.loadAuthRevision();
  });

  Future<void> ownedMonth() => storage.saveBossHours(
    '2026-10',
    {'2026-10-01': 8},
    refreshedAt: moment,
    expectedScope: scope,
    expectedAuthRevision: authRevision,
  );

  test('一次严格解析返回金额、新鲜证明与所属日期，返回集合不可变', () async {
    await ownedMonth();
    final snapshot = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: scope,
    );
    expect(snapshot.isValid, isTrue);
    expect(snapshot.consistent, isTrue);
    expect(snapshot.hours, {'2026-10-01': 8});
    expect(snapshot.knownDates, hasLength(31));
    expect(snapshot.confirmedDates, hasLength(31));
    expect(snapshot.ownedDates, hasLength(31));
    expect(await storage.loadBossHoursOwner('2026-10'), scope);
    expect(() => snapshot.hours['2026-10-01'] = 2, throwsUnsupportedError);
    expect(() => snapshot.confirmedDates.clear(), throwsUnsupportedError);
    expect(() => snapshot.ownedDates.clear(), throwsUnsupportedError);
    final stale = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment.add(const Duration(minutes: 16)),
      expectedScope: scope,
    );
    expect(stale.confirmedDates, isEmpty);
    expect(stale.knownDates, hasLength(31));
    final future = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment.subtract(const Duration(seconds: 1)),
    );
    expect(future.confirmedDates, isEmpty);
  });

  test('旧无身份写仅撤销涉及日期owner，可信单日回查可恢复', () async {
    await ownedMonth();
    await storage.saveBossHoursForDate('2026-10-02', 4, refreshedAt: moment);
    final partial = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: scope,
    );
    expect(partial.ownedDates, hasLength(30));
    expect(partial.ownedDates, isNot(contains('2026-10-02')));
    expect(await storage.loadBossHoursOwner('2026-10'), isNull);
    await storage.saveBossHoursForDate(
      '2026-10-02',
      5,
      refreshedAt: moment,
      expectedScope: scope,
      expectedAuthRevision: authRevision,
    );
    expect(await storage.loadBossHoursOwner('2026-10'), scope);
    await storage.markBossHoursDateChanged('2026-10-02');
    final changed = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: scope,
    );
    expect(changed.confirmedDates, hasLength(30));
    expect(changed.ownedDates, hasLength(30));
  });

  test('scope为空的测试适配器可保存但永不赋owner', () async {
    await storage.clearAuthInfo();
    final revision = await storage.loadAuthRevision();
    await storage.saveBossHoursForDate(
      '2026-10-01',
      6.5,
      refreshedAt: moment,
      expectedAuthRevision: revision,
    );
    final snapshot = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
    );
    expect(snapshot.hours['2026-10-01'], 6.5);
    expect(snapshot.confirmedDates, contains('2026-10-01'));
    expect(snapshot.ownedDates, isEmpty);
    expect(await storage.loadBossHoursOwner('2026-10'), isNull);
  });

  test('新账号不能信旧owner，旧请求在队列开始前被拒绝写入', () async {
    await ownedMonth();
    await storage.saveToken('fixture-next-token');
    await storage.saveTeamContext(teamNo: 'team-b', personNo: 'person-b');
    final nextScope = (await storage.loadBossCredentialScope())!;
    final snapshot = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: nextScope,
    );
    expect(snapshot.ownedDates, isEmpty);
    await storage.saveBossHoursForDate(
      '2026-10-01',
      19,
      refreshedAt: moment,
      expectedScope: scope,
      expectedAuthRevision: authRevision,
    );
    expect((await storage.loadBossHours('2026-10'))['2026-10-01'], 8);
  });

  test('读取等待写队列完成，不把新金额与旧证明拼成可用快照', () async {
    await ownedMonth();
    platform.pauseKey = 'flutter.${StorageKeys.bossHoursKey('2026-10')}';
    platform.entered = Completer<void>();
    platform.release = Completer<void>();
    final write = storage.saveBossHoursForDate(
      '2026-10-01',
      9,
      refreshedAt: moment,
      expectedScope: scope,
      expectedAuthRevision: authRevision,
    );
    await platform.entered!.future;
    var done = false;
    final read = storage
        .loadBossMonthSnapshot('2026-10', now: moment, expectedScope: scope)
        .then((value) {
          done = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    platform.release!.complete();
    await write;
    final snapshot = await read;
    expect(snapshot.consistent, isTrue);
    expect(snapshot.hours['2026-10-01'], 9);
    expect(snapshot.ownedDates, hasLength(31));
  });

  test('原生写等待期间切换账号会撤销proof和owner，旧结果不能变成新身份事实', () async {
    await ownedMonth();
    platform.pauseKey = 'flutter.${StorageKeys.bossHoursKey('2026-10')}';
    platform.entered = Completer<void>();
    platform.release = Completer<void>();
    final write = storage.saveBossHoursForDate(
      '2026-10-01',
      9,
      refreshedAt: moment,
      expectedScope: scope,
      expectedAuthRevision: authRevision,
    );
    await platform.entered!.future;
    await storage.saveToken('fixture-next-token');
    await storage.saveTeamContext(teamNo: 'team-b', personNo: 'person-b');
    platform.release!.complete();
    await write;
    final snapshot = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: scope,
    );
    expect(snapshot.confirmedDates, isEmpty);
    expect(snapshot.ownedDates, isEmpty);
    expect(await storage.loadBossHoursOwner('2026-10'), isNull);
  });

  test('污染JSON即使带旧证明和owner也不能成为已确认数据', () async {
    await ownedMonth();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      StorageKeys.bossHoursKey('2026-10'),
      '{"2026-10-01":"bad"}',
    );
    final snapshot = await storage.loadBossMonthSnapshot(
      '2026-10',
      now: moment,
      expectedScope: scope,
    );
    expect(snapshot.isValid, isFalse);
    expect(snapshot.confirmedDates, isEmpty);
    expect(snapshot.ownedDates, isEmpty);
  });
}
