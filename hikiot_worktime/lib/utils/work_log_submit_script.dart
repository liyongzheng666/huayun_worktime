import 'dart:convert';

import 'work_log_csv_parser.dart';

/// BOSS 工作日志提交报文构造
///
/// 通过重放 `SaveWorkLogObject` 报文直接提交，不再依赖 DOM 与自研控件。
///
/// 安全约定：**不保存任何会话凭据**。BOSS 把 `Password` 等凭据放在每个业务
/// 请求体里，若把会话上下文存进 APP，等同于在本地明文保存登录凭据。
/// 因此这里只在 WebView 内就地复用页面刚发出过的请求里的 `para`，
/// 凭据始终停留在网页会话中。
class WorkLogSubmitScript {
  WorkLogSubmitScript._();

  /// 保存工作日志的服务名。
  static const String saveServiceUri =
      'Hoteam.InforCenter.WorkReportService.SaveWorkLogObject';

  /// 日志类型（LOGTYPE）编码表，取自表单下拉的 DataSource。
  ///
  /// 按「拓展预留」要求列全，便于以后 CSV 出现其他类型时直接可用。
  static const Map<String, String> logTypeCodes = {
    '会议': '1',
    '培训': '2',
    '研发': '5',
    '实施': '6',
    '测试': '7',
    '质量': '8',
    '文案': '9',
    '设计': '10',
    '维护': '11',
    '售前': '12',
    '营销': '13',
    '经管': '14',
    '市场': '15',
    '财务': '16',
    '人力': '17',
    '管理': '18',
    '文档': '19',
    '其他': '20',
  };

  /// CSV 里用「无」表示不填，BOSS 报文里对应空串。
  /// 实测切到「设计」类型后，PROJECTPHASE / PHASEACTIVITIES 提交的就是 ""。
  static String normalizeOptional(String value) {
    final trimmed = value.trim();
    return (trimmed.isEmpty || trimmed == '无') ? '' : trimmed;
  }

  static String? resolveLogType(String workType) =>
      logTypeCodes[workType.trim()];

  /// 生成「会话是否就绪」探测脚本。
  ///
  /// 用于一键提交时轮询等待登录完成——登录后首页会自动发若干请求，
  /// 一旦抓到带 UserID 的 para 即可提交。
  ///
  /// 返回 JSON：`{"ready":true,"userName":"..."}`
  static String buildSessionProbeScript({required String captureStoreName}) {
    return '''
      (function() {
        var store = window.$captureStoreName || [];
        for (var i = store.length - 1; i >= 0; i--) {
          var entry = store[i];
          if (!entry || !entry.body) continue;
          try {
            var parsed = JSON.parse(entry.body);
            if (parsed && parsed.para && parsed.para.UserID) {
              return JSON.stringify({
                ready: true,
                userName: parsed.para.UserName || ''
              });
            }
          } catch (e) {}
        }
        return JSON.stringify({ ready: false });
      })();
    ''';
  }

  /// 从抓包记录里提取提交所需的固定常量。
  ///
  /// 提取的是项目 ID、项目编码、审核人 ID —— 都是业务标识而非凭据，
  /// 可以安全持久化复用。**不提取也不保存 `Password` 等会话凭据。**
  ///
  /// 返回 JSON：`{"ok":true,"projectId":...,"projectCode":...,"auditor":...}`
  static String buildExtractConstantsScript({
    required String captureStoreName,
  }) {
    return '''
      (function() {
        var store = window.$captureStoreName || [];

        for (var i = store.length - 1; i >= 0; i--) {
          var entry = store[i];
          if (!entry || !entry.body) continue;
          try {
            var outer = JSON.parse(entry.body);
            if (!outer.para || outer.para.ServiceUri !== ${jsonEncode(saveServiceUri)}) continue;

            var inner = JSON.parse(outer.content).para;
            var data = JSON.parse(inner.workLogData);
            if (!data.PROJECTID) continue;

            return JSON.stringify({
              ok: true,
              projectId: data.PROJECTID,
              projectCode: data.PROJECTCODE || '',
              auditor: data.AUDITOR || '',
              projectName: data.PROJECTNAME || ''
            });
          } catch (e) {}
        }

        return JSON.stringify({
          ok: false,
          message: '抓包里没有找到保存日志的记录，请先在网页上手动保存一条日志'
        });
      })();
    ''';
  }

  /// 构造 `workLogData` 业务对象（新建日志）。
  ///
  /// [projectId] / [projectCode] / [auditor] 是随账号和项目固定的值，
  /// 由调用方从一次成功提交中获取后传入，不在此硬编码。
  static Map<String, dynamic> buildWorkLogData({
    required WorkLogEntry entry,
    required String actWork,
    required String projectId,
    required String projectCode,
    required String auditor,
  }) {
    final logType = resolveLogType(entry.workType);
    if (logType == null) {
      throw ArgumentError('未知的工作类型：${entry.workType}');
    }

    final date = DateTime.parse(entry.date);
    final logDate =
        '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
    final selectDate = '${date.year}-${date.month}-${date.day}';

    return {
      'ObjectType': 'WORKLOG',
      'SelectDate': selectDate,
      'empty': null,
      'AUDITOR': auditor,
      'LOGTYPE': logType,
      'ENAME': entry.title,
      'PROJECTPHASE': normalizeOptional(entry.stage),
      'PMTASKEUID': '',
      'PHASEACTIVITIES': normalizeOptional(entry.activity),
      'ZICHADOC': '0',
      'ZICHADOCCHART': '0',
      'LOGCONTENT': entry.content,
      'ZICHAADD': '0',
      'ZICHAEDIT': '0',
      'ZICHADEL': '0',
      'STATICSCANNINGDEFECTSNUMBER': '0',
      'WORKSOLO': '',
      'ACTWORK': actWork,
      'EXTRAWORK': '0.0',
      'LOGPERCENTS': '100',
      'WORKSTATE': 'Normal',
      'WEEKPLANSTATE': 'Normal',
      'DELAYREASON': '',
      'SOLVE': '',
      'DIFFICULTY': '',
      'SUPPORT': '',
      'WEEKPLAN': '',
      'TODAYPLAN': '',
      'LOGEXPERIENCE': '',
      'LOGFOUCER': '',
      'LOGDATE': logDate,
      'LOGSTATE': '0',
      'TASKEUID': '',
      'TASKID': '',
      'PROJECTID': projectId,
      'PROJECTNAME': entry.projectName,
      'PROJECTCODE': projectCode,
    };
  }

  /// 生成提交脚本。
  ///
  /// 脚本会从抓包存储里取最近一条带 `ServiceUri` 的请求，复用其 `para`
  /// 作为会话上下文，只替换 `ServiceUri` 与业务数据后重新发出。
  ///
  /// 返回 JSON：`{"ok":true,"objectId":"WORKLOG_xxx"}` 或 `{"ok":false,"reason":...}`
  static String build({
    required Map<String, dynamic> workLogData,
    required String captureStoreName,
  }) {
    final dataJson = jsonEncode(jsonEncode(workLogData));

    return '''
      (function() {
        var WORKLOG_DATA = $dataJson;
        var SERVICE_URI = ${jsonEncode(saveServiceUri)};

        // 从抓包记录里找一条带完整会话上下文的请求，复用它的 para。
        // 这样凭据只存在于网页会话中，不落到 APP 存储。
        //
        // 只要求 UserID：ServiceUri 由我们自己设置，不能拿它当筛选条件。
        // 登录后首页自动发的 CheckUserUnReadMessage / GetIntervals 都不带
        // ServiceUri，但 para 是完整的——要求它会让刚登录时取不到会话。
        function findPara() {
          var store = window.$captureStoreName || [];
          for (var i = store.length - 1; i >= 0; i--) {
            var entry = store[i];
            if (!entry || !entry.body) continue;
            try {
              var parsed = JSON.parse(entry.body);
              if (parsed && parsed.para && parsed.para.UserID) {
                return parsed.para;
              }
            } catch (e) {}
          }
          return null;
        }

        var para = findPara();
        if (!para) {
          return JSON.stringify({
            ok: false,
            reason: 'noSession',
            message: '未捕获到会话上下文，请先在页面上做一次任意操作（如切换日期）'
          });
        }

        // 外层 para：复制一份并换掉 ServiceUri，避免污染原对象
        var outer = {};
        for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
        outer.ServiceUri = SERVICE_URI;

        // 内层 para：同样的上下文 + 业务数据
        var inner = {};
        for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
        delete inner.ServiceUri;
        inner.workLogData = WORKLOG_DATA;
        inner.ctrlEvent = { o: { id: 'guid0' } };

        var payload = JSON.stringify({
          para: outer,
          content: JSON.stringify({ para: inner })
        });

        // 同步请求，便于把结果直接返回给 evaluateJavascript
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

        try {
          xhr.send(payload);
        } catch (e) {
          return JSON.stringify({ ok: false, reason: 'network', message: String(e) });
        }

        if (xhr.status !== 200) {
          return JSON.stringify({
            ok: false, reason: 'http', status: xhr.status,
            message: (xhr.responseText || '').substring(0, 300)
          });
        }

        // 成功时响应形如 {"d":"{\\"d\\":\\"WORKLOG_xxx\\"}"}，逐层解开取 ID
        var text = xhr.responseText || '';
        var objectId = null;
        try {
          var lvl1 = JSON.parse(text).d;
          var lvl2 = typeof lvl1 === 'string' ? JSON.parse(lvl1).d : lvl1;
          objectId = typeof lvl2 === 'string' ? lvl2 : null;
        } catch (e) {}

        if (objectId && objectId.indexOf('WORKLOG_') === 0) {
          return JSON.stringify({ ok: true, objectId: objectId });
        }
        return JSON.stringify({
          ok: false, reason: 'unexpected',
          message: text.substring(0, 300)
        });
      })();
    ''';
  }
}
