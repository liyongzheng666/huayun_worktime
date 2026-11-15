import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/session_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SessionService', () {
    late StorageService storage;
    late List<String> remoteLogoutTokens;
    var clearWebSessionCount = 0;
    var forgetBossCredentialsCount = 0;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      storage = StorageService();
      remoteLogoutTokens = <String>[];
      clearWebSessionCount = 0;
      forgetBossCredentialsCount = 0;
    });

    SessionService createService({bool failRemoteLogout = false}) {
      return SessionService(
        storage: storage,
        remoteLogout: (token) async {
          remoteLogoutTokens.add(token);
          if (failRemoteLogout) {
            throw Exception('network down');
          }
        },
        clearWebSession: () async {
          clearWebSessionCount++;
        },
        forgetBossCredentials: () async {
          forgetBossCredentialsCount++;
          expect(await storage.loadToken(), isNotNull);
        },
      );
    }

    test('logs out remotely, clears web session and local auth', () async {
      await storage.saveToken('token-1');
      await storage.saveUserName('张三');
      final service = createService();

      await service.logout();

      expect(remoteLogoutTokens, ['token-1']);
      expect(clearWebSessionCount, 1);
      expect(forgetBossCredentialsCount, 1);
      expect(await storage.loadToken(), isNull);
      expect(await storage.loadUserName(), isNull);
    });

    test(
      'still clears web session and local auth when remote logout fails',
      () async {
        await storage.saveToken('token-1');
        final service = createService(failRemoteLogout: true);

        await service.logout();

        expect(remoteLogoutTokens, ['token-1']);
        expect(clearWebSessionCount, 1);
        expect(await storage.loadToken(), isNull);
      },
    );

    test(
      'does not call remote logout when token is missing or invalid debug token',
      () async {
        final service = createService();

        await service.clearRemoteAndWebSession(null);
        await service.clearRemoteAndWebSession('');
        await service.clearRemoteAndWebSession('   ');
        await service.clearRemoteAndWebSession(
          'INVALID_TOKEN_FOR_DEBUG_TESTING_12345',
        );
        await service.clearRemoteAndWebSession(
          'invalid_token_for_debug_testing_12345',
        );

        expect(remoteLogoutTokens, isEmpty);
        expect(clearWebSessionCount, 5);
      },
    );

    test('trims token before calling remote logout', () async {
      final service = createService();

      await service.clearRemoteAndWebSession('  token-1  ');

      expect(remoteLogoutTokens, ['token-1']);
      expect(clearWebSessionCount, 1);
    });

    test('Cookie 清理失败仍清除本地凭据，让登录页可以重新清理并重试', () async {
      await storage.saveToken('expired-token');
      await storage.saveUserName('张三');
      final service = SessionService(
        storage: storage,
        remoteLogout: (_) async {},
        clearWebSession: () async => throw StateError('Cookie store failed'),
      );

      await expectLater(service.logout(), completes);

      expect(await storage.loadToken(), isNull);
      expect(await storage.loadUserName(), isNull);
    });

    test('主账号自动过期不忘记华天密码，但撤销当前身份范围', () async {
      await storage.saveToken('expired-token');
      await storage.saveTeamContext(teamNo: 'team', personNo: 'person');
      expect(await storage.loadBossCredentialScope(), isNotNull);
      await createService().logout(forgetBossCredentials: false);
      expect(forgetBossCredentialsCount, 0);
      expect(await storage.loadToken(), isNull);
      expect(await storage.loadBossCredentialScope(), isNull);
      expect(clearWebSessionCount, 1);
    });

    test('清除记忆发生在身份撤销前，安全存储异常不阻断主账号退出', () async {
      await storage.saveToken('test-token');
      var forgot = false;
      final service = SessionService(
        storage: storage,
        remoteLogout: (_) async {},
        clearWebSession: () async {},
        forgetBossCredentials: () async {
          expect(await storage.loadToken(), 'test-token');
          forgot = true;
          throw StateError('test storage unavailable');
        },
      );
      await expectLater(service.logout(), completes);
      expect(forgot, isTrue);
      expect(await storage.loadToken(), isNull);
    });
  });
}
