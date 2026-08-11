import 'dart:convert';

import 'boss_session_script.dart';

/// 从 BOSS 的历史工作日志里读取当前的项目与审核人
///
/// **为什么需要它**：`PROJECTID` / `PROJECTCODE` / `AUDITOR` 不是常量——用户的
/// 项目和审核人会经常更换。任何「学一次就永久沿用」的做法都会在换项目后
/// 拿旧 ID 提交新项目的日志，而且不报错。正确做法是每次提交前现查。
///
/// **数据来源**：`InforCenter.WorkReport.ProjectService.GetHisWorkLogList`。
/// 该服务由「我的工作日志」页面自己调用，返回历史日志的网格数据，
/// 一次就能拿到三个值。实测响应形状（每行是一组列对象）：
///
/// ```
/// ColName:"PROJECTID"    ColText:"面向比亚迪…项目-自筹"  ColValue:"PROJECT_899d…"
/// ColName:"PROJECTCODE"  ColText:"PROJECT_75e0…"        ColValue:"PROJECT_75e0…"
/// ColName:"AUDITOR"      ColText:"杨亚伦"                ColValue:"USERINFO_891c…"
/// ```
///
/// 注意 `PROJECTID` 这一列里，**项目名在 ColText、项目 ID 在 ColValue**。
/// 早期正则去找名为 `PROJECTNAME` 的列，而它根本不存在，因此一直匹配不到。
///
/// **为什么解 JSON 而不用正则**：一次响应里有多行历史日志，正则很容易把
/// 第 1 行的项目和第 5 行的审核人拼在一起。按行解析才能保证三个值同源。
class WorkLogHistoryLookup {
  WorkLogHistoryLookup._();

  static const String serviceUri =
      'InforCenter.WorkReport.ProjectService.GetHisWorkLogList';

  /// 生成查询脚本。
  ///
  /// [preferredProjectName] 为 CSV 中当日的项目名；历史日志可能横跨多个项目，
  /// 必须挑出与当天要提交的项目一致的那一行，否则会张冠李戴。
  ///
  /// 策略：先原样重放页面自己发过的那次请求以拿到**最新**数据；
  /// 重放失败（该视图可能依赖服务端查询上下文）时退回用已抓到的响应。
  /// 两条路都走不通才算失败。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"projectId":..,"projectCode":..,"auditor":..,"auditorName":..,
  ///   "projectName":..,"source":"replay"|"captured","rowCount":N}`
  static String build({
    required String captureStoreName,
    required String preferredProjectName,
  }) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}
        ${BossSessionScript.gridPreamble()}

        var SERVICE_URI = ${jsonEncode(serviceUri)};
        var PREFERRED = ${jsonEncode(preferredProjectName)};

        // 找到页面自己发过的那次请求，连参数一起复用。
        // 不自己构造参数：ViewName / ParaList / CustomViewFilterString 的取值
        // 依赖页面上下文，猜不出来；原样重放才可靠。
        function findHisRequest() {
          var store = bossCaptured();
          for (var i = store.length - 1; i >= 0; i--) {
            var e = store[i];
            if (!e || !e.body) continue;
            try {
              var outer = JSON.parse(e.body);
              if (!outer.para || outer.para.ServiceUri !== SERVICE_URI) continue;
              return { entry: e, inner: JSON.parse(outer.content).para };
            } catch (err) {}
          }
          return null;
        }

        function readRow(map) {
          var projectId = pickId(map, 'PROJECTID', 'PROJECT_');
          var auditor = pickId(map, 'AUDITOR', 'USERINFO_');
          if (!projectId || !auditor) return null;

          // PROJECTID 列的 ColText 就是项目名
          var projectCol = map['PROJECTID'] || {};
          return {
            projectId: projectId,
            projectCode: pickId(map, 'PROJECTCODE', 'PROJECT_'),
            auditor: auditor,
            // 审核人姓名，用于让用户在提交前肉眼核对——
            // 提交给错误的审批人是这里最有后果的一种错误
            auditorName: (map['AUDITOR'] || {}).text || '',
            projectName: projectCol.text || ''
          };
        }

        var found = findHisRequest();
        if (!found) {
          return JSON.stringify({
            ok: false,
            reason: 'noHistoryRequest',
            message: '还没抓到历史日志查询。请到「我的工作日志」点开一个已填过的日期'
          });
        }

        // 先重放拿最新数据；失败再退回已抓到的响应
        var grid = null;
        var source = '';

        var para = bossFindPara();
        if (para) {
          var res = bossCall(para, SERVICE_URI, found.inner);
          if (res.ok && res.text) {
            grid = unwrapGrid(res.text);
            if (grid) source = 'replay';
          }
        }
        if (!grid) {
          grid = unwrapGrid(found.entry.response || '');
          if (grid) source = 'captured';
        }
        if (!grid) {
          return JSON.stringify({
            ok: false,
            reason: 'noRows',
            message: '历史日志查询没有返回数据'
          });
        }

        // 优先取项目名与 CSV 一致的那一行；历史日志可能横跨多个项目，
        // 取错行会把日志记到别的项目名下。
        var fallback = null;
        for (var r = 0; r < grid.Rows.length; r++) {
          var hit = readRow(rowMap(grid.Rows[r]));
          if (!hit) continue;
          if (PREFERRED && hit.projectName === PREFERRED) {
            hit.ok = true;
            hit.source = source;
            hit.rowCount = grid.Rows.length;
            hit.matchedPreferred = true;
            return JSON.stringify(hit);
          }
          if (!fallback) fallback = hit;
        }

        if (fallback) {
          fallback.ok = true;
          fallback.source = source;
          fallback.rowCount = grid.Rows.length;
          fallback.matchedPreferred = false;
          return JSON.stringify(fallback);
        }

        return JSON.stringify({
          ok: false,
          reason: 'noUsableRow',
          rowCount: grid.Rows.length,
          message: '历史日志里没有同时含项目与审核人的记录'
        });
      })();
    ''';
  }
}
