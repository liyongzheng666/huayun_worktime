import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_credentials_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingDeleteStorage extends FlutterSecureStorage {
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('测试安全存储删除失败');
  }
}

void main() {
  late StorageService storage;
  late BossCredentialsService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = StorageService();
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'team', personNo: 'person');
    service = BossCredentialsService(storage: storage);
  });

  Future<void> remember() => service.rememberForCurrentScope(
    userName: 'boss-user',
    password: 'test-only-secret',
  );

  test('只通过安全存储保存，重新创建服务仍能按主账号读取', () async {
    await remember();
    final loaded = await BossCredentialsService(
      storage: storage,
    ).loadForCurrentScope();
    expect(loaded?.userName, 'boss-user');
    expect(loaded?.password, 'test-only-secret');
    expect(loaded?.automaticLoginEnabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().map(prefs.get).toString(),
      isNot(contains('test-only-secret')),
    );
  });

  test('新token未确认身份不读旧凭据，同身份重新确认后恢复，不同员工隔离', () async {
    await remember();
    await storage.saveToken('new-token');
    expect(await service.loadForCurrentScope(), isNull);
    await storage.saveTeamContext(teamNo: 'team', personNo: 'person');
    expect((await service.loadForCurrentScope())?.password, 'test-only-secret');
    await storage.saveTeamContext(teamNo: 'team', personNo: 'other-person');
    expect(await service.loadForCurrentScope(), isNull);
  });

  test('清除会停自动登录并删除系统安全项', () async {
    await remember();
    await service.bindCurrentSession();
    await service.forgetCurrentScope();
    expect(await service.loadForCurrentScope(), isNull);
    expect(await service.isCurrentSessionBound(), isFalse);
  });

  test('删除失败先停用，重开服务也不会继续使用旧密码', () async {
    await remember();
    final failing = BossCredentialsService(
      storage: storage,
      secureStorage: _FailingDeleteStorage(),
    );
    await expectLater(failing.forgetCurrentScope(), throwsStateError);
    final saved = await service.loadForCurrentScope();
    expect(saved?.automaticLoginEnabled, isFalse);
    expect(service.claimAutomaticAttempt(saved!), isFalse);
  });

  test('确定认证错误可持久停用，手工重新成功记住后再启用', () async {
    await remember();
    await service.disableAutomaticLogin((await service.currentScope())!);
    expect(
      (await service.loadForCurrentScope())?.automaticLoginEnabled,
      isFalse,
    );
    await remember();
    expect(
      (await service.loadForCurrentScope())?.automaticLoginEnabled,
      isTrue,
    );
  });

  test('网络类失败只在当前进程短暂退避，避免并发连续尝试', () async {
    await remember();
    var now = DateTime(2026, 11, 16);
    final backoff = BossCredentialsService(storage: storage, now: () => now);
    final saved = (await backoff.loadForCurrentScope())!;
    expect(backoff.claimAutomaticAttempt(saved), isTrue);
    expect(backoff.claimAutomaticAttempt(saved), isFalse);
    now = now.add(const Duration(minutes: 6));
    expect(backoff.claimAutomaticAttempt(saved), isTrue);
  });

  test('认证期间主账号变化，不得把旧登录结果绑定或保存到新身份', () async {
    final old = (await service.currentScope())!;
    await storage.saveTeamContext(teamNo: 'team', personNo: 'new-person');
    await expectLater(
      service.rememberForCurrentScope(
        userName: 'old-boss',
        password: 'test-only-secret',
        expectedScope: old,
      ),
      throwsStateError,
    );
    await expectLater(
      service.bindCurrentSession(expectedScope: old),
      throwsStateError,
    );
    expect(await service.loadForCurrentScope(), isNull);
  });
}
