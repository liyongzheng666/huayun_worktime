import 'dart:convert';

import 'boss_session_script.dart';

/// BOSS 抓包诊断
///
/// 自动获取项目信息失败时，用来回答「到底卡在哪一步」。
///
/// 只报成败是没法定位的——「没登录」「登录了但没打开业务页」「打开了但
/// iframe 没被注入」「注入了但响应形状不认识」这四种在最终结果上长得一模一样，
/// 原因却完全不同。因此这里按 frame 逐个列出注入与抓取情况。
///
/// **为什么诊断的重点是 frame**：早期版本的取常量脚本只读主框架的抓包记录，
/// 而 BOSS 的业务模块跑在 iframe 里，导致无论用户怎么操作都扫不到数据
/// （见 踩坑记录 2.7）。这是历史上最费时间的一次误判，
/// 所以诊断必须能一眼看出「数据在哪个 frame、我们读的是哪个」。
///
/// **安全约定**：只输出 para 的 key 列表，绝不输出值——
/// BOSS 把 `Password` 明文放在每个请求体里（踩坑记录 3.12），
/// 诊断报告是要复制给别人看的，带上值等于泄露凭据。
class WorkLogDiagnosticsScript {
  WorkLogDiagnosticsScript._();

  /// 生成诊断脚本。
  ///
  /// [preferredProjectName] 为 CSV 里的项目名，用来判断抓到的响应里
  /// 是否真的出现过这个项目。
  ///
  /// 返回 JSON：按 frame 列出注入状态、请求数、是否含项目信息。
  static String build({
    required String captureStoreName,
    required String preferredProjectName,
  }) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}

        var PREFERRED = ${jsonEncode(preferredProjectName)};

        // 项目/审核人标识的字面量特征，用于判断某个 frame 里到底有没有料
        var RE_PROJECT = /PROJECT_[A-Za-z0-9]+/;
        var RE_AUDITOR = /USERINFO_[A-Za-z0-9]+/;

        // —— 逐 frame 统计 ——
        // 这是本诊断的核心：数据在哪个 frame、哪个 frame 没被注入，
        // 一眼可辨。全局汇总反而会把「读错 frame」这类问题藏起来。
        var frames = [];
        function walk(win, path) {
          var info = {
            path: path,
            url: null,
            hooked: false,
            captured: 0,
            withPara: 0,
            withProject: 0,
            error: null
          };
          try {
            info.url = win.location.href;
            var store = win.$captureStoreName;
            info.hooked = !!store;
            if (store) {
              info.captured = store.length;
              for (var i = 0; i < store.length; i++) {
                var e = store[i];
                if (!e) continue;
                if (e.body && e.body.indexOf('"para"') >= 0) info.withPara++;
                var text = (e.response || '') + (e.body || '');
                if (RE_PROJECT.test(text)) info.withProject++;
              }
            }
            frames.push(info);
            for (var j = 0; j < win.frames.length; j++) {
              walk(win.frames[j], path + '/' + j);
            }
          } catch (err) {
            // 跨域 frame 读不到，这本身就是有价值的诊断信息
            info.error = String(err);
            frames.push(info);
          }
        }
        walk(window, 'main');

        // —— 汇总视角 ——
        var all = bossCaptured();
        var report = {
          frameCount: frames.length,
          frames: frames,
          totalCaptured: all.length,
          preferredProjectName: PREFERRED,
          preferredSeen: false,
          projectIdSeen: false,
          auditorSeen: false,
          session: null
        };

        for (var k = 0; k < all.length; k++) {
          var entry = all[k];
          if (!entry) continue;
          var text = (entry.response || '') + (entry.body || '');
          if (!text) continue;
          if (!report.preferredSeen && PREFERRED && text.indexOf(PREFERRED) >= 0) {
            report.preferredSeen = true;
          }
          if (!report.projectIdSeen && RE_PROJECT.test(text)) {
            report.projectIdSeen = true;
          }
          if (!report.auditorSeen && RE_AUDITOR.test(text)) {
            report.auditorSeen = true;
          }
        }

        var para = bossFindPara();
        if (para) {
          // 只列 key，不带值——诊断报告会被复制出去，带值等于泄露凭据
          report.session = { found: true, paraKeys: Object.keys(para) };
        } else {
          report.session = { found: false };
        }

        // 给出一句人话结论，避免读报告的人还要自己推断
        if (!para) {
          report.conclusion = '未捕获到会话，通常是还没登录，或登录后页面没发过业务请求';
        } else if (report.totalCaptured === 0) {
          report.conclusion = '抓包钩子没生效，检查是否以 forMainFrameOnly:false 注入';
        } else if (!report.projectIdSeen) {
          report.conclusion = '会话正常但没抓到任何项目信息，请在网页上打开一次「我的工作日志」列表';
        } else {
          report.conclusion = '抓到了项目信息但解析失败，可能是响应形状与正则不匹配';
        }

        return JSON.stringify(report);
      })();
    ''';
  }
}
