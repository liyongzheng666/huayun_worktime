import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_auditor_lookup.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 只替换网页读数，保留实际配置解析与 SharedPreferences 读写流程。
class _UnusedController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResolutionService extends WorkLogSubmitService {
  _ResolutionService() : super(_UnusedController());

  List<BossAuditor> candidates = [];
  List<BossProject> projects = [];
  Map<String, String>? history;
  int auditorReads = 0;
  String? queriedProjectId;

  @override
  Future<List<BossProject>> listProjects({
    int retries = 6,
    Duration interval = const Duration(milliseconds: 500),
  }) async => projects;

  @override
  Future<Map<String, String>?> learnConstants(String projectName) async =>
      history;

  @override
  Future<List<BossAuditor>> lookupAuditors({
    String projectId = '',
    int retries = 4,
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    auditorReads++;
    queriedProjectId = projectId;
    return candidates;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const auditor = BossAuditor(
    id: ';USERINFO_current',
    name: '当前审核人',
    source: BossAuditorSource.setting,
  );
  const project = {'projectId': 'PROJECT_a', 'projectName': '项目甲'};

  test('已绑定项目缺审核人时重新抓取并修复缓存', () async {
    final storage = StorageService();
    await storage.saveBossBinding('CSV甲', project);
    final service = _ResolutionService()..candidates = [auditor];

    final result = await service.resolveConstants('CSV甲');

    expect(service.auditorReads, 1);
    expect(service.queriedProjectId, 'PROJECT_a');
    expect(result.constants?['auditor'], auditor.id);
    expect(result.needsAuditorPick, isFalse);
    expect((await storage.loadBossBinding('CSV甲'))?['auditor'], auditor.id);
  });

  test('残缺缓存遇到多个历史候选时提供选择且不擅自写入', () async {
    final storage = StorageService();
    await storage.saveBossBinding('CSV甲', project);
    final candidates = [
      const BossAuditor(id: ';USERINFO_a', name: '甲'),
      const BossAuditor(id: ';USERINFO_b', name: '乙'),
    ];
    final service = _ResolutionService()..candidates = candidates;

    final result = await service.resolveConstants('CSV甲');

    expect(result.auditors, candidates);
    expect(result.needsAuditorPick, isTrue);
    expect((await storage.loadBossBinding('CSV甲'))?['auditor'], isNull);
  });

  test('残缺缓存抓取失败后下次仍可补齐', () async {
    await StorageService().saveBossBinding('CSV甲', project);
    final service = _ResolutionService();
    expect((await service.resolveConstants('CSV甲')).needsAuditorPick, isTrue);
    service.candidates = [auditor];
    expect((await service.resolveConstants('CSV甲')).needsAuditorPick, isFalse);
    expect(service.auditorReads, 2);
  });

  test('缓存只有审核人 ID 时按同 ID 补姓名，不换成其他人', () async {
    await StorageService().saveBossBinding('CSV甲', {
      ...project,
      'auditor': ';USERINFO_old',
    });
    final service = _ResolutionService()
      ..candidates = [
        auditor,
        const BossAuditor(id: ';USERINFO_old', name: '已选审核人'),
      ];

    final result = await service.resolveConstants('CSV甲');

    expect(result.constants?['auditor'], ';USERINFO_old');
    expect(result.constants?['auditorName'], '已选审核人');
  });

  test('完整缓存继续复用，不要求网页再次提供人员信息', () async {
    final bound = {
      ...project,
      'auditor': auditor.id,
      'auditorName': auditor.name,
    };
    await StorageService().saveBossBinding('CSV甲', bound);
    final service = _ResolutionService();
    final result = await service.resolveConstants('CSV甲');
    expect(result.constants, bound);
    expect(service.auditorReads, 0);
  });

  test('CSV 项目没有历史日志时仍从个人设置取得审核人', () async {
    // 使用用户样本的项目名，不把个人 CSV 工作内容纳入公开仓库。
    const name = '几何约束求解引擎A路径二期攻关项目-自筹';
    final service = _ResolutionService()
      ..projects = [const BossProject(id: 'PROJECT_new', name: name)]
      ..candidates = [auditor];
    final result = await service.resolveConstants(name);
    expect(result.needsProjectPick, isFalse);
    expect(result.needsAuditorPick, isFalse);
    expect(result.constants?['projectId'], 'PROJECT_new');
    expect(result.constants?['auditor'], auditor.id);
    expect(service.queriedProjectId, 'PROJECT_new');
  });

  test('有冲突的默认审核人时交给用户选择', () async {
    await StorageService().saveBossBinding('CSV甲', project);
    final service = _ResolutionService()
      ..candidates = [
        auditor,
        const BossAuditor(
          id: ';USERINFO_other',
          source: BossAuditorSource.setting,
        ),
      ];
    final result = await service.resolveConstants('CSV甲');
    expect(result.needsAuditorPick, isTrue);
    expect(result.auditors, hasLength(2));
  });

  test('只有历史项目可用时仍以当前默认审核人为准', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old', 'auditorName': '旧人'}
      ..candidates = [auditor];
    final result = await service.resolveConstants('项目甲');
    expect(result.constants?['auditor'], auditor.id);
    expect(result.constants?['auditorName'], auditor.name);
  });

  test('业务接口唯一候选优先于旧设置和历史记录', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old'}
      ..candidates = [
        auditor,
        const BossAuditor(
          id: ';USERINFO_live',
          name: '当前项目审核人',
          source: BossAuditorSource.service,
        ),
      ];
    final result = await service.resolveConstants('项目甲');
    expect(result.constants?['auditor'], ';USERINFO_live');
    expect(service.queriedProjectId, 'PROJECT_a');
  });

  test('业务接口有多人时不让旧历史审核人跳过选择', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old'}
      ..candidates = [
        auditor,
        const BossAuditor(id: ';USERINFO_a', source: BossAuditorSource.service),
        const BossAuditor(id: ';USERINFO_b', source: BossAuditorSource.service),
      ];
    final result = await service.resolveConstants('项目甲');
    expect(result.needsAuditorPick, isTrue);
    expect(await StorageService().loadBossBinding('项目甲'), isNull);
  });

  test('只有别的项目的一条历史审核人时仍必须手工确认', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old'}
      ..projects = [const BossProject(id: 'PROJECT_b', name: '项目乙')]
      ..candidates = [const BossAuditor(id: ';USERINFO_old', name: '甲项目审核人')];
    final result = await service.resolveConstants('项目乙');
    expect(result.needsAuditorPick, isTrue);
    expect(WorkLogSubmitService.preferredAuditor(service.candidates), isNull);
    expect(await StorageService().loadBossBinding('项目乙'), isNull);
  });

  test('首次解析有多个默认设置时不能拿旧历史绕过选择', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old'}
      ..candidates = [
        auditor,
        const BossAuditor(
          id: ';USERINFO_other',
          source: BossAuditorSource.setting,
        ),
      ];
    final result = await service.resolveConstants('项目甲');
    expect(result.needsAuditorPick, isTrue);
    expect(await StorageService().loadBossBinding('项目甲'), isNull);
  });

  test('CSV 项目需要改选时同样带上当前默认审核人', () async {
    final service = _ResolutionService()
      ..history = {...project, 'auditor': ';USERINFO_old'}
      ..candidates = [auditor];
    final result = await service.resolveConstants('CSV乙');
    expect(result.needsProjectPick, isTrue);
    expect(result.constants?['auditor'], auditor.id);
    expect(result.constants?['auditorName'], auditor.name);
  });
}
