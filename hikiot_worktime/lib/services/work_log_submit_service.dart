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

  /// 已保存的配置是否可用于 [projectName] 这个项目。
  ///
  /// 用户的项目和审核人会换，一次学会就永久沿用是错的：换项目后继续用
  /// 旧的 PROJECTID，会把新项目的日志记到旧项目名下，而且不会报错。
  static bool constantsUsableFor(
    Map<String, String> saved,
    String projectName,
  ) {
    if (saved['projectId']?.isNotEmpty != true) return false;
    final savedName = saved['projectName'] ?? '';
    if (savedName.isEmpty || projectName.isEmpty) return true;
    return savedName == projectName;
  }

  /// 取提交所需的业务标识：本地已保存且项目对得上 → 直接用，否则现学。
  Future<Map<String, String>?> resolveConstants(String projectName) async {
    final saved = await _storage.loadBossConstants();
    if (constantsUsableFor(saved, projectName)) return saved;

    return learnConstants(projectName);
  }

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
