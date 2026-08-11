import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../utils/work_log_auditor_lookup.dart';
import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_constants_scanner.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_log_diagnostics_script.dart';
import '../utils/work_log_history_lookup.dart';
import '../utils/work_log_project_list_lookup.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/work_log_submit_script.dart';
import 'storage_service.dart';

/// 提交配置的解析结果
class BossConstantsResolution {
  const BossConstantsResolution({
    this.constants,
    this.needsProjectPick = false,
    this.projects = const [],
    this.reason,
  });

  /// 取到的提交配置，null 表示没拿到。
  ///
  /// [needsProjectPick] 为 true 时这只是**预选值**，项目部分甚至可能是空的
  /// （清单扫到了但历史日志学不到时就是这样），必须等用户挑完才算数。
  final Map<String, String>? constants;

  /// 是否需要用户从 [projects] 里挑出正确的项目。
  ///
  /// **确认前不写绑定**，用户放弃时不会留下一个错误的对应关系，下次仍会重问。
  final bool needsProjectPick;

  /// 从 BOSS 爬到的全量项目清单，供选择框列出；扫不到时为空。
  final List<BossProject> projects;

  /// 没能给出可提交配置时的原因，一句话，直接显示给用户。
  final String? reason;

  bool get hasConstants => constants != null;
}

/// 提交结果
class WorkLogSubmitResult {
  const WorkLogSubmitResult({required this.ok, this.objectId, this.message});

  final bool ok;
  final String? objectId;
  final String? message;
}

/// BOSS 工作日志提交的业务编排
///
/// 从网页页面里抽出来，是为了让「后台无头会话」和「可见网页页」共用同一套流程。
/// 两处各写一遍的话，改一处漏一处——本项目已经在 `findPara` 上吃过这个亏
/// （见 docs/踩坑记录.md 2.7、3.11）。
///
/// 本类只做业务，不碰 UI：确认对话框、提示、剪贴板都由调用方负责。
class WorkLogSubmitService {
  WorkLogSubmitService(this._controller, {StorageService? storage})
    : _storage = storage ?? StorageService();

  final InAppWebViewController _controller;
  final StorageService _storage;

  static const String _store = WorkLogRequestCapture.storeName;

  /// 记录「这份配置是为 CSV 里的哪个项目名学的」，作为缓存匹配键。
  static const String bindingKey = 'csvProjectName';

  /// 已保存的配置是否可用于 CSV 里的 [csvProjectName] 这个项目。
  ///
  /// 用户的项目和审核人会换，一次学会就永久沿用是错的：换项目后继续用
  /// 旧的 PROJECTID，会把新项目的日志记到旧项目名下，而且不会报错。
  ///
  /// **比的是绑定键，不是 BOSS 那边的项目名。** 两边写法本就可能不同
  /// （BOSS 多个「(2)」之类），拿 BOSS 名去比 CSV 名会永远不等，于是
  /// 每次提交都重学；更要命的是 `learnConstants` 的项目偏好匹配用的是
  /// 同一个比较，失效后会静默取历史日志的第一行——用户做过多个项目时
  /// 直接学到别的项目的 ID，且全程无提示。
  static bool constantsUsableFor(
    Map<String, String> saved,
    String csvProjectName,
  ) {
    if (saved['projectId']?.isNotEmpty != true) return false;

    final boundTo = saved[bindingKey];
    if (boundTo == null) {
      // 旧版本存的配置没有绑定键。名字一致的可以就地认作已绑定；
      // 不一致的恰恰可能是当初静默 fallback 学来的，不能无声沿用，
      // 交给调用方重学一次并让用户确认。
      final bossName = saved['projectName'] ?? '';
      if (bossName.isEmpty || csvProjectName.isEmpty) return true;
      return bossName == csvProjectName;
    }

    if (boundTo.isEmpty || csvProjectName.isEmpty) return true;
    return boundTo == csvProjectName;
  }

  /// CSV 里的 [csvProjectName] 是否已经有可用配置。
  ///
  /// 按项目名记住的绑定和那份「最近一次使用的配置」都要看。只看后者的话，
  /// 已经绑好的项目会被后台学习当成「还没配置」，一边反复去学，一边弹
  /// 「已自动获取配置」——用户明明什么都没做。
  static Future<bool> hasUsableConstantsFor(
    String csvProjectName, {
    StorageService? storage,
  }) async {
    final store = storage ?? StorageService();
    final bound = await store.loadBossBinding(csvProjectName);
    if (bound?['projectId']?.isNotEmpty == true) return true;
    return constantsUsableFor(await store.loadBossConstants(), csvProjectName);
  }

  /// 取提交所需的业务标识。
  ///
  /// 顺序刻意是「**先爬全量项目清单，再谈其他**」：
  ///
  /// 项目清单登录后就能扫到（首页自动发 `GetMyJoinProjectGrid`，踩坑记录 3.21），
  /// 不要求用户在 BOSS 里做过任何事，是整条链上最稳的一环。而
  /// [learnConstants] 靠的是历史日志，用户没在 BOSS 填过这个项目就学不到。
  /// 早先把清单挂在「学到之后」才用，等于让最稳的一环去等最脆的一环：
  /// 项目名对不上又恰好没有历史日志时，明明扫得到、用户也认得出的那个项目
  /// 根本没机会拿出来给他选，直接就报「未取到项目信息」了。
  ///
  /// 现在清单是主路径，[learnConstants] 降为「提供审核人 + 提供一个预选项」。
  ///
  /// 名字**完全相同**时自动选中，不打扰用户；对不上才把
  /// [BossConstantsResolution.needsProjectPick] 置位，交给调用方弹选择框。
  /// 排序上「像」不算数——是不是同一个项目只有用户知道。
  Future<BossConstantsResolution> resolveConstants(String csvProjectName) async {
    final remembered = await _rememberedConstants(csvProjectName);
    if (remembered != null) {
      return BossConstantsResolution(
        constants: remembered,
        // 已经绑好了，不该为了「万一用户要改选」去等清单——扫一次就走，
        // 扫到就在确认框里给「改选」入口，扫不到这次就没有，不影响提交
        projects: await listProjects(retries: 0),
      );
    }

    // —— 主路径：爬全量项目清单 ——
    final projects = await listProjects();

    // 历史日志仍然试一次：它同时给出审核人，也给出一个「上次用的项目」当预选
    final learned = await learnConstants(csvProjectName);

    // 审核人不在项目清单里（它是个人设置，不是项目属性），必须单独取
    final auditor = _auditorFrom(learned) ?? await lookupAuditor();
    if (auditor == null) {
      // 拿空审核人提交会把日志发给错误的审批人（或直接被拒），宁可停下
      return BossConstantsResolution(
        projects: projects,
        reason: projects.isEmpty
            ? '没取到项目清单，也没取到工作日志的审核人'
            : '已扫到 ${projects.length} 个项目，但没取到工作日志的审核人',
      );
    }

    // 清单里有与 CSV 一字不差的项目 → 就是它，不必打扰用户。
    // 只认「一字不差」：差一个「(2)」就可能是另一个项目，替用户判等于
    // 把「静默绑错项目」换身衣服重来一遍，而且更难被发现。
    final exact = csvProjectName.isEmpty ? null : _findExact(projects, csvProjectName);
    if (exact != null) {
      return BossConstantsResolution(
        constants: await _bind(
          _composeConstants(auditor: auditor, project: exact),
          csvProjectName,
        ),
        projects: projects,
      );
    }

    // 清单没扫到，但历史日志学到的就是同名项目 → 同样不必打扰
    if (learned != null &&
        csvProjectName.isNotEmpty &&
        (learned['projectName'] ?? '') == csvProjectName) {
      return BossConstantsResolution(
        constants: await _bind(learned, csvProjectName),
        projects: projects,
      );
    }

    if (projects.isEmpty && learned == null) {
      return const BossConstantsResolution(reason: '没扫到任何项目');
    }

    // 对不上：把全量清单端出来让用户自己选。
    // learned 为 null 时预选配置里没有项目，选择框必须强制选一个才放行。
    return BossConstantsResolution(
      constants: learned ?? _composeConstants(auditor: auditor),
      needsProjectPick: true,
      projects: projects,
    );
  }

  /// 之前为这个 CSV 项目名记住过的配置。
  ///
  /// 先查按项目名分开存的绑定，再退回那份「最近一次使用的配置」——后者只存得下
  /// 一个项目，是老版本留下的形状，只在用户还没为当前项目确认过时才轮得到它。
  Future<Map<String, String>?> _rememberedConstants(String csvProjectName) async {
    final bound = await _storage.loadBossBinding(csvProjectName);
    if (bound?['projectId']?.isNotEmpty == true) return bound;

    final saved = await _storage.loadBossConstants();
    if (!constantsUsableFor(saved, csvProjectName)) return null;

    // 旧配置就地补上绑定，免得每次都走兼容分支
    if (saved[bindingKey] == null && csvProjectName.isNotEmpty) {
      return _bind(saved, csvProjectName);
    }
    return saved;
  }

  /// 把审核人与项目拼成一份提交配置。
  ///
  /// [project] 为空时项目三项留空，表示「等用户挑」——留空是刻意的，
  /// 随手填个占位值会在忘记覆盖时变成一次静默的错误提交。
  static Map<String, String> _composeConstants({
    required BossAuditor auditor,
    BossProject? project,
  }) => {
    'projectId': project?.id ?? '',
    'projectCode': project?.code ?? '',
    'projectName': project?.name ?? '',
    'auditor': auditor.id,
    'auditorName': auditor.name,
  };

  /// 从历史日志学到的配置里取审核人，取不到返回 null。
  static BossAuditor? _auditorFrom(Map<String, String>? learned) {
    final id = learned?['auditor'] ?? '';
    if (!id.startsWith(';USERINFO_')) return null;
    return BossAuditor(id: id, name: learned?['auditorName'] ?? '');
  }

  /// 清单里名字与 [csvProjectName] 一字不差的项目，没有则返回 null。
  static BossProject? _findExact(
    List<BossProject> projects,
    String csvProjectName,
  ) {
    for (final project in projects) {
      if (project.name == csvProjectName) return project;
    }
    return null;
  }

  /// 报文里该填的项目名。
  ///
  /// 一律优先用 BOSS 的写法，让 `PROJECTNAME` 与 `PROJECTID` 同源；
  /// 只有手工配置（没有 BOSS 名）时才退回 CSV 的写法。
  static String payloadProjectName(
    Map<String, String> constants,
    String csvProjectName,
  ) => constants['projectName']?.isNotEmpty == true
      ? constants['projectName']!
      : csvProjectName;

  /// 用户在确认框里改选了别的项目时，据此重建配置。
  ///
  /// **`projectCode` 用新项目的 `EUID`**：实际抓包比对确认，日志的
  /// `PROJECTID` 就是项目的 `EID`、`PROJECTCODE` 就是项目的 `EUID`
  /// （比亚迪那条日志的两个值与项目对象的 EID/EUID 逐字相同）。
  /// 项目网格里两者同行可取，所以改选后能给出正确的编码。
  /// 只有扫不到 `EUID` 时才清空——旧项目的编码带过去是个确定错误的值，
  /// 留空还能由服务端兜底（手工配置一直是这么用的）。
  ///
  /// **`auditor` 保留**：审核人是个人设置而非项目属性——系统设置里的
  /// `WorkReport_AudtiorFocusor_defaultSetting` 存的就是当前用户的默认
  /// 审核人。因此换项目时沿用是对的。但这仍是从一次抓包得出的结论，
  /// 界面上照旧提示用户核对，不默默替换。
  static Map<String, String> constantsForProject(
    Map<String, String> constants,
    BossProject project,
  ) => {
    ...constants,
    'projectId': project.id,
    'projectName': project.name,
    'projectCode': project.code,
  };

  /// 记住「这份配置对应 CSV 里的哪个项目」，之后同名项目不再询问也不再重学。
  ///
  /// 做成静态方法是因为它只写存储、不碰网页：用户在确认框上点「是同一个」时，
  /// 后台无头会话早已销毁，此时拿不到也不需要 `InAppWebViewController`。
  /// **两处都写**：`saveBossConstants` 只存得下一份，是「最近一次使用的配置」，
  /// 供设置页显示和后台学习判断；`saveBossBinding` 按 CSV 项目名分开存，
  /// 才是真正的记忆。只写前者的话，用户在两个项目之间来回切会互相覆盖，
  /// 界面上承诺的「之后不再询问」就成了空话——而多项目正是这套机制的受众。
  static Future<Map<String, String>> bindConstants(
    Map<String, String> constants,
    String csvProjectName, {
    StorageService? storage,
  }) async {
    final bound = {...constants, bindingKey: csvProjectName};
    final store = storage ?? StorageService();
    await store.saveBossConstants(bound);
    await store.saveBossBinding(csvProjectName, bound);
    return bound;
  }

  Future<Map<String, String>> _bind(
    Map<String, String> constants,
    String csvProjectName,
  ) => bindConstants(constants, csvProjectName, storage: _storage);

  /// 扫一次网页会话，尝试学到提交配置；成功则落盘并返回。
  ///
  /// 三种来源按可靠度依次尝试：
  /// 1. 历史日志网格——按行解 JSON，三个值同源，还能拿到审核人姓名
  /// 2. 保存报文——语义精确，但要求用户先在网页上填过一条
  /// 3. 正则扫描其余响应——兜底
  Future<Map<String, String>?> learnConstants(String projectName) async {
    final fromHistory = _parseConstants(
      await runScript(
        WorkLogHistoryLookup.build(
          captureStoreName: _store,
          preferredProjectName: projectName,
        ),
      ),
    );
    if (fromHistory != null) {
      await _storage.saveBossConstants(fromHistory);
      return fromHistory;
    }

    final fromSave = _parseConstants(
      await runScript(
        WorkLogSubmitScript.buildExtractConstantsScript(captureStoreName: _store),
      ),
    );
    if (fromSave != null) {
      await _storage.saveBossConstants(fromSave);
      return fromSave;
    }

    final scanned = _parseConstants(
      await runScript(
        WorkLogConstantsScanner.build(
          captureStoreName: _store,
          preferredProjectName: projectName,
        ),
      ),
    );
    if (scanned != null) {
      await _storage.saveBossConstants(scanned);
      return scanned;
    }

    return null;
  }

  /// 扫出抓包里能认出的所有 BOSS 项目。
  ///
  /// **必须重试**：会话就绪的判定只要求抓到任意一条带 `para` 的请求
  /// （见 `BossSessionRunner._awaitSession`），而首页的「我的项目」网格
  /// 往往稍晚才返回。第一次扫空就断定「没有项目」是错的。
  ///
  /// 扫不到时返回空列表，调用方应退回到不依赖项目清单的老路径。
  Future<List<BossProject>> listProjects({
    int retries = 6,
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    for (var attempt = 0; ; attempt++) {
      final projects = WorkLogProjectListLookup.parse(
        await runScript(
          WorkLogProjectListLookup.build(captureStoreName: _store),
        ),
      );
      if (projects.isNotEmpty || attempt >= retries) return projects;
      await Future.delayed(interval);
    }
  }

  /// 扫出当前用户的工作日志审核人，取不到返回 null。
  ///
  /// 审核人**不在项目清单里**——它是个人设置（`WorkReport_AudtiorFocusor_defaultSetting`，
  /// 踩坑记录 3.21），不是项目属性。所以选好项目还得单独取它，否则凑不齐报文。
  ///
  /// 和 [listProjects] 一样要重试：会话就绪只要求抓到任意一条带 `para` 的请求，
  /// 承载设置项的那个响应可能稍晚才回来，第一次扫空不代表没有。
  Future<BossAuditor?> lookupAuditor({
    int retries = 4,
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    for (var attempt = 0; ; attempt++) {
      final auditor = WorkLogAuditorLookup.parse(
        await runScript(WorkLogAuditorLookup.build(captureStoreName: _store)),
      );
      if (auditor != null || attempt >= retries) return auditor;
      await Future.delayed(interval);
    }
  }

  /// 查询该日在 BOSS 已填报的工时，取不到返回 null（未知，不等于 0）。
  Future<double?> queryExistingHours(String dateStr) async {
    final raw = await runScript(
      WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: dateStr,
        captureStoreName: _store,
      ),
    );
    return WorkLogBossHours.parseSingleDay(raw);
  }

  /// 发起提交。
  Future<WorkLogSubmitResult> submit({
    required WorkLogEntry entry,
    required String actWork,
    required Map<String, String> constants,
  }) async {
    try {
      final workLogData = WorkLogSubmitScript.buildWorkLogData(
        entry: entry,
        actWork: actWork,
        projectId: constants['projectId']!,
        projectCode: constants['projectCode'] ?? '',
        projectName: payloadProjectName(constants, entry.projectName),
        auditor: constants['auditor'] ?? '',
      );

      final raw = await runScript(
        WorkLogSubmitScript.build(
          workLogData: workLogData,
          captureStoreName: _store,
        ),
      );

      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is Map && decoded['ok'] == true) {
        return WorkLogSubmitResult(
          ok: true,
          objectId: '${decoded['objectId']}',
        );
      }
      return WorkLogSubmitResult(
        ok: false,
        message: decoded is Map
            ? '${decoded['message'] ?? decoded['reason'] ?? '未知错误'}'
            : '未知错误',
      );
    } on ArgumentError catch (e) {
      return WorkLogSubmitResult(ok: false, message: '${e.message}');
    } catch (e) {
      return WorkLogSubmitResult(ok: false, message: '$e');
    }
  }

  /// 收集诊断信息，供学不到配置时反馈。
  ///
  /// 返回 (可读结论, 完整报告)。凭据已在脚本内打码。
  Future<(String?, String)> collectDiagnostics(String projectName) async {
    final raw = await runScript(
      WorkLogDiagnosticsScript.build(
        captureStoreName: _store,
        preferredProjectName: projectName,
      ),
    );

    Object? decoded;
    try {
      decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
    } catch (_) {
      decoded = raw;
    }

    final report = const JsonEncoder.withIndent('  ').convert({
      'stage': 'learnConstantsFailed',
      'preferredProjectName': projectName,
      'diagnostics': decoded,
    });
    final conclusion = decoded is Map ? decoded['conclusion']?.toString() : null;
    return (conclusion, report);
  }

  Future<String?> runScript(String script) async {
    try {
      final raw = await _controller.evaluateJavascript(source: script);
      debugPrint('[日志提交] 脚本返回=${raw?.toString()}');
      return raw?.toString();
    } catch (e) {
      return '{"ok":false,"reason":"evalError","message":"$e"}';
    }
  }

  /// 解析脚本返回的常量。
  ///
  /// **自动获取时审核人必须一并拿到**：首页的「我的项目」网格里有
  /// `PROJECT_xxx` 却没有工作日志的审核人；而抓包别处出现的 `USERINFO_`
  /// 往往是用户自己的 ID。只要项目 ID 就落盘的话，会拿一个错的（或空的）
  /// 审核人去提交，日志就发给了错误的审批人。
  static Map<String, String>? _parseConstants(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return null;

      final projectId = '${decoded['projectId'] ?? ''}';
      final auditor = '${decoded['auditor'] ?? ''}';
      if (projectId.isEmpty || auditor.isEmpty) return null;

      return {
        'projectId': projectId,
        'projectCode': '${decoded['projectCode'] ?? ''}',
        // 保存报文里审核人带前导分号，历史网格里不带，统一补齐
        'auditor': auditor.startsWith(';') ? auditor : ';$auditor',
        'projectName': '${decoded['projectName'] ?? ''}',
        'auditorName': '${decoded['auditorName'] ?? ''}',
      };
    } catch (e) {
      return null;
    }
  }
}
