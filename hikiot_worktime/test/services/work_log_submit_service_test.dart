import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BOSS 那边的项目名比 CSV 多一个「(2)」——用户实际遇到的差异
const _csvName = '面向比亚迪公司的项目-自筹';
const _bossName = '面向比亚迪公司的项目-自筹(2)';

void main() {
  group('提交结果分类', () {
    test('服务端确认成功', () {
      final result = WorkLogSubmitService.parseSubmitResult(
        '{"ok":true,"objectId":"WORKLOG_123"}',
      );

      expect(result.status, WorkLogSubmitStatus.submitted);
      expect(result.ok, isTrue);
      expect(result.objectId, 'WORKLOG_123');
    });

    test('当天已有日志时归类为跳过，不算提交失败', () {
      final result = WorkLogSubmitService.parseSubmitResult(
        '{"ok":false,"alreadySubmitted":true,"existingHours":8}',
      );

      expect(result.status, WorkLogSubmitStatus.alreadySubmitted);
      expect(result.ok, isFalse);
      expect(result.existingHours, 8);
    });

    test('网络检查失败时归类为暂缓', () {
      final result = WorkLogSubmitService.parseSubmitResult(
        '{"ok":false,"deferred":true,"message":"暂缓"}',
      );

      expect(result.status, WorkLogSubmitStatus.deferred);
      expect(result.message, '暂缓');
    });

    test('无法解析返回值时按结果未知暂缓，不能诱导立即重试', () {
      final result = WorkLogSubmitService.parseSubmitResult('坏数据');

      expect(result.status, WorkLogSubmitStatus.deferred);
    });

    test('只有明确标记的业务错误才算确定失败', () {
      final result = WorkLogSubmitService.parseSubmitResult(
        '{"ok":false,"failed":true,"message":"服务端拒绝"}',
      );

      expect(result.status, WorkLogSubmitStatus.failed);
      expect(result.message, '服务端拒绝');
    });

    test('未分类的执行异常按结果未知暂缓', () {
      final result = WorkLogSubmitService.parseSubmitResult(
        '{"ok":false,"reason":"evalError"}',
      );

      expect(result.status, WorkLogSubmitStatus.deferred);
    });
  });

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

      expect(WorkLogSubmitService.constantsUsableFor(saved, '另一个项目'), isFalse);
    });

    test('没有项目 ID 一律不可用', () {
      expect(
        WorkLogSubmitService.constantsUsableFor({
          WorkLogSubmitService.bindingKey: _csvName,
        }, _csvName),
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

      expect(
        WorkLogSubmitService.constantsUsableFor(legacy, _csvName),
        isFalse,
      );
    });

    test('手工配置（没有任何项目名）不被阻塞', () {
      // 手工填的只有三个 ID，没有项目名可比，此时不该拦下用户。
      // 但必须带上手工标记才算数，见下一条。
      final manual = {
        'projectId': 'PROJECT_aaa',
        'auditor': ';USERINFO_ccc',
        WorkLogSubmitService.manualKey: 'true',
      };

      expect(WorkLogSubmitService.constantsUsableFor(manual, _csvName), isTrue);
    });

    test('自动学到却没有项目名的配置，一律视为未绑定', () async {
      // 这是实际发生过的一次静默错误提交的根因。
      //
      // learnConstants 的第 2、3 条来源（保存报文 / 正则扫描）只吐三个 ID，
      // projectName 一律为空。这类配置以前和手工配置共用「没名字就放行」
      // 的分支，于是对**任何** CSV 项目名都判为可用：永远命中缓存、
      // 永不重学、永不弹选择框；确认框又因为没有 BOSS 名而不做任何提示。
      // 结果是 CSV 项目名与实际项目对不上，却一路畅通直到提交成功。
      final learned = {
        'projectId': 'PROJECT_aaa',
        'projectCode': 'PROJECT_bbb',
        'auditor': ';USERINFO_ccc',
        'projectName': '',
        'auditorName': '',
      };

      expect(
        WorkLogSubmitService.constantsUsableFor(learned, _csvName),
        isFalse,
      );
    });

    test('手工标记只认真正手工填的那一份', () {
      // 免得将来有人顺手把 manualKey 抄进自动学习的产物里，把洞又开回来
      final learned = {'projectId': 'PROJECT_aaa', 'projectName': ''};

      expect(
        WorkLogSubmitService.constantsUsableFor(learned, _csvName),
        isFalse,
      );
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

    test('两个项目来回切，各自的绑定都还在', () async {
      // 只存一份「最近使用的配置」时，切到 B 会把 A 的冲掉，
      // 切回 A 又要重新问一次——界面上承诺的「之后不再询问」就成了空话。
      // 而多项目正是这套机制的受众。
      final storage = StorageService();

      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_aaa', 'projectName': _bossName},
        _csvName,
        storage: storage,
      );
      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_zzz', 'projectName': '运维平台三期'},
        '运维平台',
        storage: storage,
      );

      // 后写的那个不该抹掉先写的
      expect(
        (await storage.loadBossBinding(_csvName))?['projectId'],
        'PROJECT_aaa',
      );
      expect(
        (await storage.loadBossBinding('运维平台'))?['projectId'],
        'PROJECT_zzz',
      );
    });

    test('清除配置会把按项目名记住的绑定一并清掉', () async {
      // 用户点「清除配置」的意思是全部重来；留一份看不见的绑定，
      // 会让他清完之后发现项目还是老样子，且无从下手
      final storage = StorageService();
      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_aaa'},
        _csvName,
        storage: storage,
      );

      await storage.clearBossConstants();

      expect(await storage.loadBossBinding(_csvName), isNull);
      expect(await storage.loadBossBindings(), isEmpty);
    });

    test('已绑定的项目不该再被当成「还没配置」', () async {
      // 后台学习只看那份单独的配置时，已绑好的项目会被反复去学、
      // 反复弹「已自动获取配置」——用户明明什么都没做
      final storage = StorageService();
      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_aaa', 'projectName': _bossName},
        _csvName,
        storage: storage,
      );
      // 单独那份被别的项目覆盖掉，模拟来回切项目之后的状态
      await storage.saveBossConstants({
        'projectId': 'PROJECT_zzz',
        'projectName': '运维平台三期',
        WorkLogSubmitService.bindingKey: '运维平台',
      });

      expect(
        await WorkLogSubmitService.hasUsableConstantsFor(
          _csvName,
          storage: storage,
        ),
        isTrue,
      );
      expect(
        await WorkLogSubmitService.hasUsableConstantsFor(
          '从没见过的项目',
          storage: storage,
        ),
        isFalse,
      );
    });

    test('CSV 没有项目名时不写绑定，免得所有项目挤在同一个空键上', () async {
      final storage = StorageService();
      await WorkLogSubmitService.bindConstants(
        {'projectId': 'PROJECT_aaa'},
        '',
        storage: storage,
      );

      expect(await storage.loadBossBindings(), isEmpty);
    });
  });

  group('可信度：能不能不经确认直接拿去提交', () {
    // 这一组里有落盘的用例，不能靠别的 group 的 setUp 顺手初始化
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('有项目 ID 也有 BOSS 项目名才算可信', () {
      expect(
        WorkLogSubmitService.trustworthy({
          'projectId': 'PROJECT_aaa',
          'projectName': _bossName,
        }),
        isTrue,
      );
    });

    test('只有 ID 没有 BOSS 项目名一律不可信', () {
      // 名字不是装饰——它是用户在确认框里唯一能核对
      // 「这个 PROJECTID 到底是哪个项目」的依据
      expect(
        WorkLogSubmitService.trustworthy({'projectId': 'PROJECT_aaa'}),
        isFalse,
      );
      expect(
        WorkLogSubmitService.trustworthy({
          'projectId': 'PROJECT_aaa',
          'projectName': '',
        }),
        isFalse,
      );
    });

    test('手工填的除外', () {
      expect(
        WorkLogSubmitService.trustworthy({
          'projectId': 'PROJECT_aaa',
          WorkLogSubmitService.manualKey: 'true',
        }),
        isTrue,
      );
    });

    test('没有项目 ID 一律不可信', () {
      expect(
        WorkLogSubmitService.trustworthy({'projectName': _bossName}),
        isFalse,
      );
    });

    test('存过一次的无名配置不会因此变得可信', () async {
      // 上一版的 BUG 会把无名配置正式写成绑定，盖上「已确认」的章；
      // 绑定表又是先查的，于是整个爬清单 + 用户选的流程被短路，
      // 用户看到的是一个没有任何出路的确认框。
      final storage = StorageService();
      await storage.saveBossBinding(_csvName, {
        'projectId': 'PROJECT_aaa',
        'auditor': ';USERINFO_ccc',
        'projectName': '',
        WorkLogSubmitService.bindingKey: _csvName,
      });

      final bound = await storage.loadBossBinding(_csvName);
      expect(WorkLogSubmitService.trustworthy(bound!), isFalse);
    });
  });

  group('从清单反查补上缺失的项目名', () {
    // 「有 ID 没名字」的配置来自 learnConstants 的保存报文 / 正则扫描两条来源。
    // 名字缺失的直接后果是用户在确认框里无从核对——界面只能显示 CSV 的写法，
    // 看起来一切正常，实际可能指向别的项目。现在爬得到全量清单，就地补回去。
    const projects = [
      BossProject(id: 'PROJECT_aaa', name: _bossName, code: 'PROJECT_bbb'),
      BossProject(id: 'PROJECT_zzz', name: '运维平台三期'),
    ];

    test('按项目 ID 补上名字，顺带补编码', () {
      final filled = WorkLogSubmitService.fillProjectName({
        'projectId': 'PROJECT_aaa',
        'auditor': ';USERINFO_ccc',
      }, projects);

      expect(filled['projectName'], _bossName);
      expect(filled['projectCode'], 'PROJECT_bbb');
    });

    test('已有的名字和编码绝不覆盖', () {
      final filled = WorkLogSubmitService.fillProjectName({
        'projectId': 'PROJECT_aaa',
        'projectName': '用户自己确认过的写法',
        'projectCode': 'PROJECT_原本的',
      }, projects);

      expect(filled['projectName'], '用户自己确认过的写法');
      expect(filled['projectCode'], 'PROJECT_原本的');
    });

    test('清单里查不到就保持原样，不编一个名字', () {
      // 补不上时确认框会挂出「未能确认 BOSS 那边的项目名」，那也比编强
      final filled = WorkLogSubmitService.fillProjectName({
        'projectId': 'PROJECT_不在清单里',
      }, projects);

      expect(filled['projectName'] ?? '', '');
    });

    test('没有项目 ID 时原样返回，不至于崩', () {
      expect(WorkLogSubmitService.fillProjectName(const {}, projects), isEmpty);
    });
  });

  group('报文里的项目名', () {
    test('优先用 BOSS 的写法，让名字与 PROJECTID 同源', () {
      expect(
        WorkLogSubmitService.payloadProjectName({
          'projectName': _bossName,
        }, _csvName),
        _bossName,
      );
    });

    test('手工配置没有 BOSS 名时才退回 CSV 的写法', () {
      expect(
        WorkLogSubmitService.payloadProjectName({'projectId': 'x'}, _csvName),
        _csvName,
      );
      expect(
        WorkLogSubmitService.payloadProjectName({'projectName': ''}, _csvName),
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
