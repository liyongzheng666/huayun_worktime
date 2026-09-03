import 'dart:convert';

import 'boss_session_script.dart';
import 'work_log_constants_scanner.dart';
import 'work_log_submit_script.dart';

/// BOSS 中一条已提交日志。
///
/// [rawData] 是 `GetObjectData` 返回的完整业务对象，只在内存中保留。更新时基于
/// 原对象覆盖用户改动的字段，避免丢掉当前版本尚不认识的公司定制字段。
class BossWorkLogRecord {
  const BossWorkLogRecord({required this.objectId, required this.rawData});

  final String objectId;
  final Map<String, dynamic> rawData;

  String get date => '${rawData['LOGDATE_DisplayValue'] ?? ''}';
  String get title => '${rawData['ENAME'] ?? ''}';
  String get content => '${rawData['LOGCONTENT'] ?? ''}';
  String get projectName =>
      '${rawData['PROJECTID_DisplayValue'] ?? rawData['PROJECTNAME'] ?? ''}';
  double? get hours => _toDouble(rawData['ACTWORK']);

  static double? _toDouble(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
}

enum WorkLogUpdateStatus { updated, deferred, failed }

class WorkLogUpdateResult {
  const WorkLogUpdateResult({required this.status, this.message, this.hours});

  final WorkLogUpdateStatus status;
  final String? message;
  final double? hours;
}

class BossWorkLogReference {
  const BossWorkLogReference({required this.date, required this.objectId});

  final String date;
  final String objectId;
}

/// 已提交日志的读取与更新脚本。
///
/// 真机抓包已确认：
/// - 读取：`GetObjectData(ObjectID: WORKLOG_xxx)`；
/// - 更新：仍用 `SaveWorkLogObject`，但 `workLogData` 必须携带原记录的
///   `ObjectID` / `EID` / `SelectID`。
class WorkLogEditScript {
  WorkLogEditScript._();

  static String buildFetch({
    required String objectId,
    required String captureStoreName,
  }) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}

        var OBJECT_ID = ${jsonEncode(objectId)};
        var para = bossFindPara();
        if (!para) return ${BossSessionScript.noSessionResult};

        var res = bossCall(
          para,
          ${jsonEncode(WorkLogConstantsScanner.objectServiceUri)},
          { ObjectID: OBJECT_ID }
        );
        if (!res.ok) return JSON.stringify(res);

        var data = res.data;
        if (typeof data === 'string') {
          try { data = JSON.parse(data); } catch (e) { data = null; }
        }
        if (!data || data.EID !== OBJECT_ID) {
          return JSON.stringify({
            ok: false,
            reason: 'invalidObject',
            message: '读取到的日志记录与目标 ID 不一致'
          });
        }
        return JSON.stringify({ ok: true, objectId: OBJECT_ID, data: data });
      })();
    ''';
  }

  /// 从可见 WebView 最近打开过的对象详情中识别日志 ID 与日期。
  ///
  /// 用户在 BOSS 页面点开历史日志后，页面会调用 `GetObjectData`。这里只返回
  /// 两个业务索引，不导出对象内容，更不会碰会话字段。
  static String buildDiscoverCaptured({required String captureStoreName}) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}

        function unwrapObject(text) {
          var value = text;
          for (var depth = 0; depth < 6; depth++) {
            if (typeof value === 'string') {
              try { value = JSON.parse(value); } catch (e) { return null; }
              continue;
            }
            if (value && typeof value === 'object' && value.d !== undefined) {
              value = value.d;
              continue;
            }
            break;
          }
          return value && typeof value === 'object' ? value : null;
        }

        var store = bossCaptured();
        for (var i = store.length - 1; i >= 0; i--) {
          var entry = store[i];
          if (!entry || !entry.body || !entry.response) continue;
          try {
            var outer = JSON.parse(entry.body);
            if (!outer.para ||
                outer.para.ServiceUri !== ${jsonEncode(WorkLogConstantsScanner.objectServiceUri)}) {
              continue;
            }
            var data = unwrapObject(entry.response);
            var objectId = String((data && data.EID) || '');
            var date = String((data && data.LOGDATE_DisplayValue) || '');
            if (objectId.indexOf('WORKLOG_') !== 0 ||
                !/^\\d{4}-\\d{2}-\\d{2}\$/.test(date)) {
              continue;
            }
            return JSON.stringify({ ok: true, objectId: objectId, date: date });
          } catch (e) {}
        }
        return JSON.stringify({ ok: false, reason: 'notFound' });
      })();
    ''';
  }

  static BossWorkLogReference? parseDiscoveredReference(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return null;
      final objectId = '${decoded['objectId'] ?? ''}';
      final date = '${decoded['date'] ?? ''}';
      if (!objectId.startsWith('WORKLOG_') ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        return null;
      }
      return BossWorkLogReference(date: date, objectId: objectId);
    } catch (_) {
      return null;
    }
  }

  static BossWorkLogRecord? parseFetchResult(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true || decoded['data'] is! Map) {
        return null;
      }
      final objectId = '${decoded['objectId'] ?? ''}';
      if (!objectId.startsWith('WORKLOG_')) return null;
      final data = Map<String, dynamic>.from(decoded['data'] as Map);
      if ('${data['EID'] ?? ''}' != objectId) return null;
      return BossWorkLogRecord(objectId: objectId, rawData: data);
    } catch (_) {
      return null;
    }
  }

  /// 基于服务端原对象构造更新报文，只覆盖用户明确修改的三个字段。
  static Map<String, dynamic> buildUpdatedData({
    required BossWorkLogRecord record,
    required String title,
    required String content,
    required String actWork,
  }) {
    final data = Map<String, dynamic>.from(record.rawData);
    final objectId = record.objectId;

    data
      ..['ObjectType'] = 'WORKLOG'
      ..['ObjectID'] = objectId
      ..['EID'] = objectId
      ..['SelectID'] = objectId
      ..['empty'] = null
      ..['ENAME'] = title
      ..['TaskName'] = title
      ..['LOGCONTENT'] = content
      ..['ACTWORK'] = actWork
      ..['ProjectID'] = '${data['PROJECTID'] ?? ''}'
      ..['ProjectCode'] = '${data['PROJECTCODE'] ?? ''}'
      ..['LogPercents'] = '${data['LOGPERCENTS'] ?? '100'}'
      ..['TaskEUID'] = '${data['TASKEUID'] ?? ''}'
      ..['TaskID'] = '${data['TASKID'] ?? ''}';
    return data;
  }

  static String buildUpdate({
    required Map<String, dynamic> workLogData,
    required String captureStoreName,
  }) {
    final dataJson = jsonEncode(jsonEncode(workLogData));
    final objectId = '${workLogData['EID'] ?? ''}';
    final expectedTitle = '${workLogData['ENAME'] ?? ''}';
    final expectedContent = '${workLogData['LOGCONTENT'] ?? ''}';
    final expectedHours = '${workLogData['ACTWORK'] ?? ''}';

    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}

        var WORKLOG_DATA = $dataJson;
        var OBJECT_ID = ${jsonEncode(objectId)};
        var EXPECTED_TITLE = ${jsonEncode(expectedTitle)};
        var EXPECTED_CONTENT = ${jsonEncode(expectedContent)};
        var EXPECTED_HOURS = ${jsonEncode(expectedHours)};
        var para = bossFindPara();
        if (!para) return ${BossSessionScript.noSessionResult};

        function fetchCurrent() {
          var result = bossCall(
            para,
            ${jsonEncode(WorkLogConstantsScanner.objectServiceUri)},
            { ObjectID: OBJECT_ID }
          );
          if (!result.ok) return { ok: false, cause: result.reason || 'network' };
          var data = result.data;
          if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) { data = null; }
          }
          if (!data || data.EID !== OBJECT_ID) {
            return { ok: false, cause: 'invalidObject' };
          }
          return { ok: true, data: data };
        }

        function matchesExpected(data) {
          return String(data.ENAME || '') === EXPECTED_TITLE &&
            String(data.LOGCONTENT || '') === EXPECTED_CONTENT &&
            parseFloat(data.ACTWORK) === parseFloat(EXPECTED_HOURS);
        }

        // 更新前先确认原对象仍存在。缺少这一步时，错误 ID 有可能被保存接口
        // 当成新建，从而重新制造同日重复日志。
        var before = fetchCurrent();
        if (!before.ok) {
          return JSON.stringify({
            ok: false,
            deferred: true,
            reason: 'preflightUnavailable',
            message: '未能确认原日志仍然存在，本次已暂缓修改'
          });
        }

        var saved = bossCall(
          para,
          ${jsonEncode(WorkLogSubmitScript.saveServiceUri)},
          {
            workLogData: WORKLOG_DATA,
            ctrlEvent: { o: { id: 'guid0' } }
          }
        );

        // 不依赖保存响应判断：网络中断时服务端可能已经处理，重新读取原 ID
        // 并逐项比对才是最终事实，也能证明更新没有变成另一条新记录。
        var after = fetchCurrent();
        if (after.ok && matchesExpected(after.data)) {
          return JSON.stringify({
            ok: true,
            objectId: OBJECT_ID,
            hours: parseFloat(after.data.ACTWORK)
          });
        }
        if (!after.ok) {
          return JSON.stringify({
            ok: false,
            deferred: true,
            reason: 'updateResultUnknown',
            cause: saved.reason || after.cause,
            message: '网络通信不稳定，修改结果暂时无法确认，请勿立即重试'
          });
        }
        return JSON.stringify({
          ok: false,
          failed: true,
          reason: saved.reason || 'notUpdated',
          message: 'BOSS 未保存本次修改，原日志内容没有变化'
        });
      })();
    ''';
  }

  static WorkLogUpdateResult parseUpdateResult(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map) {
        return const WorkLogUpdateResult(status: WorkLogUpdateStatus.deferred);
      }
      final hours = BossWorkLogRecord._toDouble(decoded['hours']);
      if (decoded['ok'] == true) {
        return WorkLogUpdateResult(
          status: WorkLogUpdateStatus.updated,
          message: decoded['message']?.toString(),
          hours: hours,
        );
      }
      if (decoded['failed'] == true) {
        return WorkLogUpdateResult(
          status: WorkLogUpdateStatus.failed,
          message: decoded['message']?.toString(),
        );
      }
      return WorkLogUpdateResult(
        status: WorkLogUpdateStatus.deferred,
        message: decoded['message']?.toString(),
      );
    } catch (_) {
      return const WorkLogUpdateResult(status: WorkLogUpdateStatus.deferred);
    }
  }
}
