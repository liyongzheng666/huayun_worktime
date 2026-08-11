import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_constants_scanner.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_log_diagnostics_script.dart';
import '../utils/work_log_history_lookup.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/work_log_submit_script.dart';
import 'storage_service.dart';

/// 提交配置的解析结果
class BossConstantsResolution {
  const BossConstantsResolution({this.constants, this.needsBindingConfirm = false});

  /// 取到的提交配置，null 表示没拿到
  final Map<String, String>? constants;

  /// 是否需要用户确认「CSV 的项目名 ↔ BOSS 的项目名 是同一个项目」。
  ///
  /// 只在刚学到配置且两边名字不一致时为 true。**确认前不写绑定键**，
  /// 用户拒绝时不会留下一个错误的绑定，下次仍会重新学。
  final bool needsBindingConfirm;

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

  /// 取提交所需的业务标识：已绑定当前 CSV 项目 → 直接用，否则现学。
  ///
  /// 学到的配置若与 CSV 项目名不一致，**不会自动绑定**，而是把
  /// [BossConstantsResolution.needsBindingConfirm] 置位交给调用方去问用户。
  Future<BossConstantsResolution> resolveConstants(String csvProjectName) async {
    final saved = await _storage.loadBossConstants();
    if (constantsUsableFor(saved, csvProjectName)) {
      // 旧配置就地补上绑定键，免得每次都走上面那条兼容分支
      if (saved[bindingKey] == null && csvProjectName.isNotEmpty) {
        return BossConstantsResolution(
          constants: await _bind(saved, csvProjectName),
        );
      }
      return BossConstantsResolution(constants: saved);
    }

    final learned = await learnConstants(csvProjectName);
    if (learned == null) return const BossConstantsResolution();

    // 名字对得上就没什么可确认的，直接绑定
    final bossName = learned['projectName'] ?? '';
    if (bossName.isEmpty || bossName == csvProjectName) {
      return BossConstantsResolution(
        constants: await _bind(learned, csvProjectName),
      );
    }

    return BossConstantsResolution(
      constants: learned,
      needsBindingConfirm: true,
    );
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

  /// 记住「这份配置对应 CSV 里的哪个项目」，之后同名项目不再询问也不再重学。
  ///
  /// 做成静态方法是因为它只写存储、不碰网页：用户在确认框上点「是同一个」时，
  /// 后台无头会话早已销毁，此时拿不到也不需要 `InAppWebViewController`。
  static Future<Map<String, String>> bindConstants(
    Map<String, String> constants,
    String csvProjectName, {
    StorageService? storage,
  }) async {
    final bound = {...constants, bindingKey: csvProjectName};
    await (storage ?? StorageService()).saveBossConstants(bound);
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
