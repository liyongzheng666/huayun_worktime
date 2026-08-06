import 'dart:convert';

/// 从抓包记录中扫描提交所需的固定业务标识
///
/// 为什么不自己构造查询：BOSS 的列表接口是有状态视图，必须先由 `GetTitle`
/// 在服务端建立查询上下文，单独调 `GetDataGridList` 只会返回空行
/// （实测 status 200、Rows 为空）。改为收割页面自己产生的响应。
///
/// **两种数据形状都要认**——这是实测踩过的坑：
/// - 详情形状（打开某条日志）：`"PROJECTID":"PROJECT_xxx"`
/// - 列表形状（打开日志列表）：`"ColName":"PROJECTNAME",…,"ColValue":"PROJECT_xxx"`
///
/// 只认前者会导致「用户明明打开了列表却扫不到」。
///
/// 实现上对响应原文做正则匹配而非逐层 JSON 解析——BOSS 的响应是多层转义的
/// JSON 字符串，层数随接口而异，正则对各层都适用。
class WorkLogConstantsScanner {
  WorkLogConstantsScanner._();

  static const String objectServiceUri =
      'InforCenter.Common.ObjectService.GetObjectData';

  /// 生成扫描脚本。
  ///
  /// [preferredProjectName] 为 CSV 里的项目名；存在多个项目时优先取
  /// 同时包含该名称的那份响应，避免选错项目。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"projectId":..,"projectCode":..,"auditor":..,"shape":..}`
  static String build({
    required String captureStoreName,
    required String preferredProjectName,
  }) {
    return '''
      (function() {
        var PREFERRED = ${jsonEncode(preferredProjectName)};
        var store = window.$captureStoreName || [];

        // 响应是多层转义的 JSON，反斜杠数量随嵌套层数变化，
        // 因此统一用 \\\\*" 容忍任意层级的转义。

        // —— 详情形状：打开某条日志时的完整记录 ——
        var RE_D_PROJECT_ID = /"PROJECTID\\\\*"\\s*:\\s*\\\\*"(PROJECT_[A-Za-z0-9]+)/;
        var RE_D_PROJECT_CODE = /"PROJECTCODE\\\\*"\\s*:\\s*\\\\*"(PROJECT_[A-Za-z0-9]+)/;
        var RE_D_AUDITOR = /"AUDITOR\\\\*"\\s*:\\s*\\\\*"(;?USERINFO_[A-Za-z0-9]+)/;

        // —— 列表形状：ColName / ColText / ColValue 三元组 ——
        // 中间隔着 ColText 等字段，故用有界的非贪婪匹配
        var RE_L_PROJECT_ID =
          /ColName\\\\*"\\s*:\\s*\\\\*"PROJECTNAME\\\\*"[\\s\\S]{0,600}?ColValue\\\\*"\\s*:\\s*\\\\*"(PROJECT_[A-Za-z0-9]+)/;
        var RE_L_AUDITOR =
          /ColName\\\\*"\\s*:\\s*\\\\*"AUDITOR\\\\*"[\\s\\S]{0,600}?ColValue\\\\*"\\s*:\\s*\\\\*"(;?USERINFO_[A-Za-z0-9]+)/;
        var RE_L_EID =
          /ColName\\\\*"\\s*:\\s*\\\\*"EID\\\\*"[\\s\\S]{0,600}?ColValue\\\\*"\\s*:\\s*\\\\*"(WORKLOG_[A-Za-z0-9]+)/;

        function first(re, text) {
          var m = re.exec(text);
          return m ? m[1] : '';
        }

        function scan(text) {
          if (!text) return null;

          // 详情形状优先：信息最全，一次拿到三个值
          var detailId = first(RE_D_PROJECT_ID, text);
          if (detailId) {
            return {
              shape: 'detail',
              projectId: detailId,
              projectCode: first(RE_D_PROJECT_CODE, text),
              auditor: first(RE_D_AUDITOR, text),
              workLogId: '',
              matchedPreferred: text.indexOf(PREFERRED) >= 0
            };
          }

          // 列表形状：没有 PROJECTCODE，但能给出 EID 供后续补查
          var listId = first(RE_L_PROJECT_ID, text);
          if (listId) {
            return {
              shape: 'list',
              projectId: listId,
              projectCode: '',
              auditor: first(RE_L_AUDITOR, text),
              workLogId: first(RE_L_EID, text),
              matchedPreferred: text.indexOf(PREFERRED) >= 0
            };
          }
          return null;
        }

        function complete(h) {
          return h && h.projectId && h.projectCode && h.auditor;
        }

        var best = null;
        var hits = 0;

        // 从最近的记录往前找，优先取项目名匹配且信息完整的那份
        for (var i = store.length - 1; i >= 0 && !(best && best.matchedPreferred && complete(best)); i--) {
          var entry = store[i];
          if (!entry) continue;

          // 请求体和响应体都扫：保存报文在请求体里，列表数据在响应体里
          var texts = [entry.response, entry.body];
          for (var t = 0; t < texts.length; t++) {
            var hit = scan(texts[t]);
            if (!hit) continue;
            hits++;
            if (!best) { best = hit; continue; }
            // 优先级：项目名匹配 > 信息完整
            if (hit.matchedPreferred && !best.matchedPreferred) { best = hit; continue; }
            if (hit.matchedPreferred === best.matchedPreferred &&
                complete(hit) && !complete(best)) { best = hit; }
          }
        }

        if (!best) {
          return JSON.stringify({
            ok: false,
            reason: 'notFound',
            capturedCount: store.length,
            message: '抓包里没有项目信息。请在网页上打开一次「我的工作日志」列表'
          });
        }

        // 列表形状缺 PROJECTCODE，按 EID 取完整记录补齐。
        // GetObjectData 是无状态的对象查询，可以单独调用。
        if (!best.projectCode && best.workLogId) {
          var para = null;
          for (var p = store.length - 1; p >= 0 && !para; p--) {
            var e2 = store[p];
            if (!e2 || !e2.body) continue;
            try {
              var parsed = JSON.parse(e2.body);
              if (parsed && parsed.para && parsed.para.UserID) para = parsed.para;
            } catch (err) {}
          }

          if (para) {
            var outer = {};
            for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
            outer.ServiceUri = ${jsonEncode(objectServiceUri)};

            var inner = {};
            for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
            delete inner.ServiceUri;
            inner.ObjectID = best.workLogId;

            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            try {
              xhr.send(JSON.stringify({
                para: outer,
                content: JSON.stringify({ para: inner })
              }));
              if (xhr.status === 200) {
                best.projectCode = first(RE_D_PROJECT_CODE, xhr.responseText);
                if (!best.auditor) {
                  best.auditor = first(RE_D_AUDITOR, xhr.responseText);
                }
                best.filledFromDetail = true;
              }
            } catch (err) {
              best.detailError = String(err);
            }
          }
        }

        return JSON.stringify({
          ok: !!best.projectId,
          projectId: best.projectId,
          projectCode: best.projectCode,
          auditor: best.auditor,
          shape: best.shape,
          workLogId: best.workLogId,
          filledFromDetail: !!best.filledFromDetail,
          matchedPreferred: best.matchedPreferred,
          hits: hits
        });
      })();
    ''';
  }
}
