import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BOSS 那边的项目名比 CSV 多一个「(2)」——用户实际遇到的差异
const _csvName = '面向比亚迪公司的项目-自筹';
const _bossName = '面向比亚迪公司的项目-自筹(2)';

void main() {
  group('提交配置与 CSV 项目名的绑定', () {
    test('绑定后即使两边名字不同也算可用', () {
      // 这是本次修复的核心：名字差一个「(2)」不该导致每次提交都重学
      final saved = {
        'projectId': 'PROJECT_aaa',
        'projectName': _bossName,
        WorkLogSubmitService.bindingKey: _csvName,
      };

      expect(WorkLogSubmitService.constantsUsableFor(saved, _csvName), isTrue);
    });

    test('换了 CSV 项目仍然必须重学', () {
      // 换项目后继续用旧 PROJECTID，会把日志记到旧项目名下且不报错，
      // 这道防线不能因为放宽匹配而失守
      final saved = {
        'projectId': 'PROJECT_aaa',
        'projectName': _bossName,
        WorkLogSubmitService.bindingKey: _csvName,
      };

      expect(
        WorkLogSubmitService.constantsUsableFor(saved, '另一个项目'),
        isFalse,
      );
    });

    test('没有项目 ID 一律不可用', () {
      expect(
        WorkLogSubmitService.constantsUsableFor(
          {WorkLogSubmitService.bindingKey: _csvName},
          _csvName,
        ),
        isFalse,
      );
    });

    test('旧配置没有绑定键：名字一致的就地认作已绑定', () {
      // 老版本存下来的配置不该在升级后被迫全部重学
      final legacy = {'projectId': 'PROJECT_aaa', 'projectName': _csvName};

      expect(WorkLogSubmitService.constantsUsableFor(legacy, _csvName), isTrue);
    });

    test('旧配置没有绑定键且名字不一致：视为未绑定，必须重新确认', () {
      // 这类配置恰恰可能是当初名字匹配失效、静默取历史第一行学来的，
      // 无声沿用等于把「可能记错项目」的状态永久固化下来
      final legacy = {'projectId': 'PROJECT_aaa', 'projectName': _bossName};

      expect(WorkLogSubmitService.constantsUsableFor(legacy, _csvName), isFalse);
    });

    test('手工配置（没有任何项目名）不被阻塞', () {
      // 手工填的只有三个 ID，没有项目名可比，此时不该拦下用户
      final manual = {'projectId': 'PROJECT_aaa', 'auditor': ';USERINFO_ccc'};

      expect(WorkLogSubmitService.constantsUsableFor(manual, _csvName), isTrue);
    });
  });

  group('写入绑定关系', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('绑定会落盘，且保留原有的业务标识', () async {
      final storage = StorageService();
      final bound = await WorkLogSubmitService.bindConstants(
        {
          'projectId': 'PROJECT_aaa',
          'projectCode': 'PROJECT_bbb',
          'auditor': ';USERINFO_ccc',
          'projectName': _bossName,
        },
        _csvName,
        storage: storage,
      );

      expect(bound[WorkLogSubmitService.bindingKey], _csvName);
      expect(bound['projectId'], 'PROJECT_aaa');

      final reloaded = await storage.loadBossConstants();
      expect(reloaded[WorkLogSubmitService.bindingKey], _csvName);
      expect(reloaded['projectName'], _bossName);
    });

    test('绑定后同一个 CSV 项目不再需要重学', () async {
      final storage = StorageService();
      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_aaa', 'projectName': _bossName},
        _csvName,
        storage: storage,
      );

      final reloaded = await storage.loadBossConstants();
      expect(
        WorkLogSubmitService.constantsUsableFor(reloaded, _csvName),
        isTrue,
      );
    });
  });

  group('报文里的项目名', () {
    test('优先用 BOSS 的写法，让名字与 PROJECTID 同源', () {
      expect(
        WorkLogSubmitService.payloadProjectName(
          {'projectName': _bossName},
          _csvName,
        ),
        _bossName,
      );
    });

    test('手工配置没有 BOSS 名时才退回 CSV 的写法', () {
      expect(
        WorkLogSubmitService.payloadProjectName({'projectId': 'x'}, _csvName),
        _csvName,
      );
      expect(
        WorkLogSubmitService.payloadProjectName(
          {'projectName': ''},
          _csvName,
        ),
        _csvName,
      );
    });
  });

  group('改选项目后重建配置', () {
    const learned = {
      'projectId': 'PROJECT_aaa',
      'projectCode': 'PROJECT_bbb',
      'auditor': ';USERINFO_ccc',
      'auditorName': '张三',
      'projectName': _bossName,
    };
    const picked = BossProject(id: 'PROJECT_zzz', name: '运维平台三期');

    test('项目 ID 与名称换成新选的', () {
      final rebuilt = WorkLogSubmitService.constantsForProject(learned, picked);

      expect(rebuilt['projectId'], 'PROJECT_zzz');
      expect(rebuilt['projectName'], '运维平台三期');
    });

    test('项目编码换成新项目的 EUID', () {
      // 日志的 PROJECTCODE 就是项目的 EUID，实际抓包比对确认；
      // 沿用旧项目的编码是个确定错误的值
      final rebuilt = WorkLogSubmitService.constantsForProject(
        learned,
        const BossProject(
          id: 'PROJECT_zzz',
          name: '运维平台三期',
          code: 'PROJECT_zzz_euid',
        ),
      );

      expect(rebuilt['projectCode'], 'PROJECT_zzz_euid');
    });

    test('扫不到 EUID 时清空编码，不留旧项目的值', () {
      // 留空还能由服务端兜底，带着旧编码则必错
      final rebuilt = WorkLogSubmitService.constantsForProject(learned, picked);

      expect(rebuilt['projectCode'], isEmpty);
    });

    test('审核人保留', () {
      // 项目清单只给了名字和 ID，没有新项目的审核人。清空会直接提交失败；
      // 沿用是个假设，因此界面上必须提示用户核对（见弹窗测试）
      final rebuilt = WorkLogSubmitService.constantsForProject(learned, picked);

      expect(rebuilt['auditor'], ';USERINFO_ccc');
      expect(rebuilt['auditorName'], '张三');
    });

    test('不就地改动传入的那份配置', () {
      final source = Map<String, String>.from(learned);
      WorkLogSubmitService.constantsForProject(source, picked);

      expect(source['projectId'], 'PROJECT_aaa');
    });
  });
}
