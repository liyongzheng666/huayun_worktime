import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/team_context_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StorageService storage;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  test('同一账号冷启动保留稳定凭据范围，token变化后必须重新确认身份', () async {
    await storage.saveToken('test-token-a');
    await storage.saveTeamContext(teamNo: 'team-a', personNo: 'person-a');
    final scope = jsonEncode(['team-a', 'person-a']);
    expect(await StorageService().loadBossCredentialScope(), scope);
    await storage.saveToken('test-token-a');
    expect(await storage.loadBossCredentialScope(), scope);
    await storage.saveToken('test-token-b');
    expect(await storage.loadBossCredentialScope(), isNull);
    await storage.saveTeamContext(teamNo: 'team-b', personNo: 'person-b');
    expect(
      await storage.loadBossCredentialScope(),
      jsonEncode(['team-b', 'person-b']),
    );
    await storage.clearAuthInfo();
    expect(await storage.loadBossCredentialScope(), isNull);
  });

  test('没有token或新团队缺少人员编号时不复用旧人员身份', () async {
    await storage.saveTeamContext(teamNo: 'team-a', personNo: 'person-a');
    expect(await storage.loadBossCredentialScope(), isNull);
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'team-a', personNo: 'person-a');
    expect(await storage.loadBossCredentialScope(), isNotNull);
    await storage.saveTeamContext(teamNo: 'team-b');
    expect(await storage.loadBossCredentialScope(), isNull);
  });

  test('旧账号团队请求迟到时不能为新token激活旧凭据范围', () async {
    await storage.saveToken('test-token-old');
    final account = Completer<Map<String, dynamic>?>();
    final service = TeamContextService(
      storage: storage,
      loadAccountDetail: () => account.future,
      changeTeam: (_) async => true,
    );
    final initialization = service.initialize();
    await Future<void>.delayed(Duration.zero);
    await storage.saveToken('test-token-new');
    account.complete({
      'teamInfoList': [
        {'teamNo': 'old-team', 'personNo': 'old-person'},
      ],
    });
    await expectLater(initialization, throwsStateError);
    expect(await storage.loadBossCredentialScope(), isNull);
  });

  test('团队选择期间切换账号，不能用旧候选激活新账号凭据范围', () async {
    await storage.saveToken('test-token-old');
    final service = TeamContextService(
      storage: storage,
      loadAccountDetail: () async => {
        'teamInfoList': [
          {'teamNo': 'old-team', 'personNo': 'old-person'},
        ],
      },
      changeTeam: (_) async => true,
    );
    final authRevision = await storage.loadAuthRevision();
    final teams = await service.loadTeams();
    await storage.saveToken('test-token-new');
    await expectLater(
      service.switchTo(teams.single, expectedAuthRevision: authRevision),
      throwsStateError,
    );
    expect(await storage.loadBossCredentialScope(), isNull);
  });
}
