import 'dart:convert';

/// BOSS 提交常量自举
///
/// 提交日志需要三个无法从 CSV 或打卡数据推导的值：
/// `PROJECTID`、`PROJECTCODE`、`AUDITOR`。
///
/// 本脚本从用户在 BOSS 里**已有的历史日志**中自动查出这些值，
/// 因此不需要用户先手动填报一次，也不需要把这些个人标识写死在代码里。
///
/// 查找链路（全部走已捕获的网页会话，不保存任何凭据）：
/// 1. 由 `CompanyID` 推出日志树节点 ID
/// 2. 逐日调 `GetDataGridList` 找出一条历史日志，取其 `EID`、`PROJECTID`、`AUDITOR`
/// 3. 对该 `EID` 调 `GetObjectData` 补齐 `PROJECTCODE`
class WorkLogBootstrapScript {
  WorkLogBootstrapScript._();

  static const String gridServiceUri =
      'InforCenter.Project.ProjectService.GetDataGridList';
  static const String objectServiceUri =
      'InforCenter.Common.ObjectService.GetObjectData';

  /// 生成诊断脚本：自举失败时，把每一步的中间结果都暴露出来。
  ///
  /// 只报成败无法定位问题——请求被拒、返回空行、列名对不上，
  /// 这三种在最终结果上长得一样，但原因完全不同。
  static String buildDiagnosticsScript({
    required String captureStoreName,
    required String preferredProjectName,
  }) {
    return '''
      (function() {
        var report = { capturedCount: 0, paraKeys: null, companyId: null,
                       nodeId: null, probes: [] };

        var store = window.$captureStoreName || [];
        report.capturedCount = store.length;

        // 列出抓到的请求，便于判断会话来源是否合适
        report.capturedUrls = [];
        for (var s = Math.max(0, store.length - 8); s < store.length; s++) {
          report.capturedUrls.push({
            url: store[s].url,
            hasPara: !!(store[s].body && store[s].body.indexOf('"para"') >= 0)
          });
        }

        var para = null;
        for (var i = store.length - 1; i >= 0 && !para; i--) {
          var e = store[i];
          if (!e || !e.body) continue;
          try {
            var p = JSON.parse(e.body);
            if (p && p.para && p.para.UserID) {
              para = p.para;
              report.paraFromUrl = e.url;
            }
          } catch (err) {}
        }

        if (!para) { report.error = 'noSession'; return JSON.stringify(report); }

        // 只列 key，不带值——避免把 Password 等凭据写进诊断报告
        report.paraKeys = Object.keys(para);
        report.companyId = para.CompanyID || null;

        var nodeId = 'WORKREPORTNODE_' +
          (para.CompanyID || '').replace('COMPANY_', '') + 'RESPONSE';
        report.nodeId = nodeId;

        function pad(n) { return n < 10 ? '0' + n : '' + n; }

        // 只探最近 5 天，诊断用途不需要全量
        var today = new Date();
        for (var back = 0; back < 5; back++) {
          var d = new Date(today.getTime() - back * 86400000);
          var dateStr = d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();

          var outer = {};
          for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
          outer.ServiceUri = ${jsonEncode(gridServiceUri)};

          var inner = {};
          for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
          delete inner.ServiceUri;
          inner.Pager = { CurrentPager: 1, RowNumber: 50, SortOrder: 'asc', SortName: '', Records: 0 };
          inner.ViewName = 'MyWorkLogListView';
          inner.ParaList = JSON.stringify({ ObjectID: [nodeId], DATETIME: [dateStr] });
          inner.CustomViewFilterString = ' 1=1 ';
          inner.OnlyQuery = 'true';

          var probe = { date: dateStr };
          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

          try {
            xhr.send(JSON.stringify({ para: outer, content: JSON.stringify({ para: inner }) }));
            probe.status = xhr.status;
            probe.rawHead = (xhr.responseText || '').substring(0, 400);

            var lvl1 = JSON.parse(xhr.responseText).d;
            var lvl2 = typeof lvl1 === 'string' ? JSON.parse(lvl1) : lvl1;
            var grid = (lvl2 && lvl2.d !== undefined) ? lvl2.d : lvl2;
            probe.hasRows = !!(grid && grid.Rows);
            probe.rowCount = (grid && grid.Rows) ? grid.Rows.length : 0;
            probe.recordsTotal = grid ? grid.RecordsTotal : null;

            // 列出第一行的所有列名，用于核对列名假设是否成立
            if (grid && grid.Rows && grid.Rows.length) {
              probe.firstRowColumns = grid.Rows[0].map(function(c) {
                return { name: c.ColName, text: c.ColText, value: c.ColValue };
              });
            }
          } catch (err) {
            probe.error = String(err);
          }
          report.probes.push(probe);

          if (probe.rowCount > 0) break;
        }

        return JSON.stringify(report);
      })();
    ''';
  }

  /// 生成自举脚本。
  ///
  /// [preferredProjectName] 为 CSV 中的项目名；存在多个项目时优先匹配它，
  /// 避免选错项目。匹配不到则退回最近一条日志所属项目。
  /// [searchDays] 为向前回溯的天数。每天一次同步请求，天数过大会长时间
  /// 阻塞 WebView，因此默认取较小值——日志是每天填的，最近几天必然命中。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"projectId":..,"projectCode":..,"auditor":..,"projectName":..}`
  static String build({
    required String captureStoreName,
    required String preferredProjectName,
    int searchDays = 30,
  }) {
    return '''
      (function() {
        var PREFERRED = ${jsonEncode(preferredProjectName)};
        var SEARCH_DAYS = $searchDays;
        var GRID_URI = ${jsonEncode(gridServiceUri)};
        var OBJECT_URI = ${jsonEncode(objectServiceUri)};

        // 只要求 UserID：登录后首页自动发的请求不带 ServiceUri，但 para 完整
        function findPara() {
          var store = window.$captureStoreName || [];
          for (var i = store.length - 1; i >= 0; i--) {
            var e = store[i];
            if (!e || !e.body) continue;
            try {
              var p = JSON.parse(e.body);
              if (p && p.para && p.para.UserID) return p.para;
            } catch (err) {}
          }
          return null;
        }

        var para = findPara();
        if (!para) {
          return JSON.stringify({ ok: false, reason: 'noSession' });
        }

        function call(serviceUri, extra) {
          var outer = {};
          for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
          outer.ServiceUri = serviceUri;

          var inner = {};
          for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
          delete inner.ServiceUri;
          for (var k3 in extra) { if (extra.hasOwnProperty(k3)) inner[k3] = extra[k3]; }

          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
          try {
            xhr.send(JSON.stringify({
              para: outer,
              content: JSON.stringify({ para: inner })
            }));
          } catch (e) { return null; }
          if (xhr.status !== 200) return null;

          // 响应统一是 {"d":"{\\"d\\": ...}"}，逐层解开
          try {
            var lvl1 = JSON.parse(xhr.responseText).d;
            var lvl2 = typeof lvl1 === 'string' ? JSON.parse(lvl1) : lvl1;
            return lvl2 && lvl2.d !== undefined ? lvl2.d : lvl2;
          } catch (e) { return null; }
        }

        // 日志树节点 ID 由 CompanyID 推导，形如
        // COMPANY_xxx -> WORKREPORTNODE_xxxRESPONSE
        var companyId = para.CompanyID || '';
        var nodeId = 'WORKREPORTNODE_' +
          companyId.replace('COMPANY_', '') + 'RESPONSE';

        function pad(n) { return n < 10 ? '0' + n : '' + n; }

        // 从表格行里按列名取值
        function cell(row, name) {
          for (var i = 0; i < row.length; i++) {
            if (row[i] && row[i].ColName === name) return row[i];
          }
          return null;
        }

        var found = null;
        var today = new Date();

        for (var back = 0; back < SEARCH_DAYS && !found; back++) {
          var d = new Date(today.getTime() - back * 86400000);
          var dateStr = d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();

          var grid = call(GRID_URI, {
            Pager: { CurrentPager: 1, RowNumber: 50, SortOrder: 'asc', SortName: '', Records: 0 },
            ViewName: 'MyWorkLogListView',
            ParaList: JSON.stringify({ ObjectID: [nodeId], DATETIME: [dateStr] }),
            CustomViewFilterString: ' 1=1 ',
            OnlyQuery: 'true'
          });

          if (!grid || !grid.Rows || !grid.Rows.length) continue;

          // 优先匹配 CSV 里的项目名，匹配不到就用当天第一条
          var fallback = null;
          for (var r = 0; r < grid.Rows.length; r++) {
            var row = grid.Rows[r];
            var projectCell = cell(row, 'PROJECTNAME');
            var eidCell = cell(row, 'EID');
            var auditorCell = cell(row, 'AUDITOR');
            if (!projectCell || !eidCell) continue;

            var candidate = {
              eid: eidCell.ColValue || eidCell.ColText,
              projectId: projectCell.ColValue || '',
              projectName: projectCell.ColText || '',
              auditor: auditorCell ? (auditorCell.ColValue || '') : ''
            };
            if (!candidate.projectId) continue;

            if (candidate.projectName === PREFERRED) { found = candidate; break; }
            if (!fallback) fallback = candidate;
          }
          if (!found) found = fallback;
        }

        if (!found) {
          return JSON.stringify({
            ok: false,
            reason: 'noHistory',
            message: '最近 ' + SEARCH_DAYS + ' 天在 BOSS 里没找到历史日志，无法自动获取项目信息'
          });
        }

        // PROJECTCODE 不在列表里，需要按 EID 取完整记录补齐
        var projectCode = '';
        var detail = call(OBJECT_URI, { ObjectID: found.eid });
        if (detail) {
          try {
            var obj = typeof detail === 'string' ? JSON.parse(detail) : detail;
            projectCode = obj.PROJECTCODE || '';
          } catch (e) {}
        }

        return JSON.stringify({
          ok: true,
          projectId: found.projectId,
          projectCode: projectCode,
          auditor: found.auditor,
          projectName: found.projectName,
          matchedPreferred: found.projectName === PREFERRED
        });
      })();
    ''';
  }
}
