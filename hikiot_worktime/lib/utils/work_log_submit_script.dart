import 'dart:convert';

import 'boss_session_script.dart';
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
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}

        var para = bossFindPara();
        if (!para) {
          return JSON.stringify({ ready: false, captured: bossCaptured().length });
        }
        return JSON.stringify({
          ready: true,
          userName: para.UserName || '',
          captured: bossCaptured().length
        });
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
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}

        var store = bossCaptured();

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
          reason: 'notFound',
          capturedCount: store.length,
          message: '抓包里没有找到保存日志的记录，请先在网页上手动保存一条日志'
        });
      })();
    ''';
  }

  /// 构造 `workLogData` 业务对象（新建日志）。
  ///
  /// [projectId] / [projectCode] / [projectName] / [auditor] 是随账号和项目
  /// 固定的值，由调用方从一次成功提交中获取后传入，不在此硬编码。
  ///
  /// [projectName] 必须是 **BOSS 那边的项目名**，不能用 CSV 里的写法。
  /// 决定工时归属的是 `PROJECTID`，名字得跟着它走；两者取自不同来源的话，
  /// 报文里这两个字段会指向不同的项目（实测 CSV 少写一个「(2)」就会这样）。
  static Map<String, dynamic> buildWorkLogData({
    required WorkLogEntry entry,
    required String actWork,
    required String projectId,
    required String projectCode,
    required String projectName,
    required String auditor,
  }) {
    final logType = resolveLogType(entry.workType);
    if (logType == null) {
      throw ArgumentError('未知的工作类型：${entry.workType}');
    }

    // 项目与审核人现在来自两个独立来源（项目清单 / 个人设置），
    // 「其中一个没取到」是真会发生的状态。空着提交不会报错，只会把日志
    // 记到错的地方或发给错的审批人——那是事后翻 BOSS 才发现的一类错误，
    // 在这里挡下来，代价只是一句提示。
    if (projectId.isEmpty) {
      throw ArgumentError('没有项目 ID，不能提交');
    }
    if (auditor.isEmpty) {
      throw ArgumentError('没有审核人，不能提交');
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
      'PROJECTNAME': projectName,
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
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}

        var WORKLOG_DATA = $dataJson;
        var SERVICE_URI = ${jsonEncode(saveServiceUri)};

        // 复用抓包里的会话上下文，凭据始终停留在网页会话中，不落到 APP 存储
        var para = bossFindPara();
        if (!para) return ${BossSessionScript.noSessionResult};

        var res = bossCall(para, SERVICE_URI, {
          workLogData: WORKLOG_DATA,
          ctrlEvent: { o: { id: 'guid0' } }
        });
        if (!res.ok) return JSON.stringify(res);

        // 成功时最内层就是新建记录的 ID
        var objectId = (typeof res.data === 'string') ? res.data : null;
        if (objectId && objectId.indexOf('WORKLOG_') === 0) {
          return JSON.stringify({ ok: true, objectId: objectId });
        }
        return JSON.stringify({
          ok: false,
          reason: 'unexpected',
          message: (res.text || '').substring(0, 300)
        });
      })();
    ''';
  }
}
