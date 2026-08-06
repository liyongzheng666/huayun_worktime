/// 网页请求抓包脚本
///
/// 目的：拿到「保存工作日志」实际发出的报文（URL、方法、请求头、请求体），
/// 从而改用直接重放报文的方式提交，摆脱对 DOM 结构和自研控件的依赖。
///
/// 两个关键点：
/// 1. 必须在 AT_DOCUMENT_START 注入，要在页面自身脚本运行前替换
///    XMLHttpRequest 与 fetch，晚了就钩不到页面已持有的原始引用。
/// 2. 必须注入到所有 frame（`forMainFrameOnly: false`）。BOSS 是门户型系统，
///    模块页跑在 iframe 里，只注入主框架会一条都抓不到。
class WorkLogRequestCapture {
  WorkLogRequestCapture._();

  /// 全局变量名，抓到的请求存放于此（每个 frame 各有一份）。
  static const String storeName = '__workLogCapturedRequests';

  /// 最多保留的请求条数，避免长时间浏览把内存撑爆。
  ///
  /// 不能太小：BOSS 经典首页加载时自身就会发约 40 个请求，
  /// 缓冲过小会把后续真正需要的业务响应挤出去（实测踩过）。
  static const int maxRecords = 100;

  /// 单条记录保留的最大字符数。
  ///
  /// 原为 6000，实测不够：BOSS 的 grid 响应一条就有 6005 字符被截断，
  /// 需要的列正好落在切口之外。截断和「形状不认识」在结果上完全一样，
  /// 曾因此误判过一轮（诊断里现在会输出 `responseTruncated` 加以区分）。
  ///
  /// 与 [maxRecords] 是一组权衡：100 条 × 60000 字符 ≈ 最坏 6 MB，
  /// 对 WebView 可以接受，而绝大多数请求远小于上限。
  static const int maxRecordChars = 60000;

  /// 生成注入脚本（在 document start 注入一次即可）。
  static String buildHookScript() {
    return '''
      (function() {
        if (window.$storeName) return; // 避免重复注入导致多层包装
        var STORE = window.$storeName = [];
        var MAX = $maxRecords;
        var MAX_CHARS = $maxRecordChars;

        function record(entry) {
          try {
            entry.at = new Date().toISOString();
            entry.frameUrl = location.href;
            STORE.push(entry);
            if (STORE.length > MAX) STORE.shift();
          } catch (e) {}
        }

        function truncate(value) {
          if (value == null) return null;
          var text;
          if (typeof value === 'string') {
            text = value;
          } else if (value instanceof FormData) {
            var pairs = [];
            try {
              value.forEach(function(v, k) { pairs.push(k + '=' + v); });
            } catch (e) {}
            text = '[FormData] ' + pairs.join('&');
          } else {
            try { text = JSON.stringify(value); } catch (e) { text = String(value); }
          }
          return text.length > MAX_CHARS
            ? text.substring(0, MAX_CHARS) + '…[截断]'
            : text;
        }

        // ---- 钩 XMLHttpRequest ----
        var rawOpen = XMLHttpRequest.prototype.open;
        var rawSend = XMLHttpRequest.prototype.send;
        var rawSetHeader = XMLHttpRequest.prototype.setRequestHeader;

        XMLHttpRequest.prototype.open = function(method, url) {
          this.__capture = { via: 'xhr', method: method, url: url, headers: {} };
          return rawOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          if (this.__capture) this.__capture.headers[name] = value;
          return rawSetHeader.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function(body) {
          var info = this.__capture;
          if (info) {
            info.body = truncate(body);
            var self = this;
            this.addEventListener('loadend', function() {
              info.status = self.status;
              try {
                info.response = truncate(
                  (self.responseType === '' || self.responseType === 'text')
                    ? self.responseText
                    : '[非文本响应]'
                );
              } catch (e) {}
              record(info);
            });
          }
          return rawSend.apply(this, arguments);
        };

        // ---- 钩 fetch ----
        if (window.fetch) {
          var rawFetch = window.fetch;
          window.fetch = function(input, init) {
            var info = {
              via: 'fetch',
              method: (init && init.method) || 'GET',
              url: (typeof input === 'string') ? input : (input && input.url),
              headers: (init && init.headers) ? init.headers : {},
              body: truncate(init && init.body)
            };
            return rawFetch.apply(this, arguments).then(function(res) {
              info.status = res.status;
              record(info);
              return res;
            }, function(err) {
              info.error = String(err);
              record(info);
              throw err;
            });
          };
        }

        // ---- 钩表单提交 ----
        // ASP.NET WebForms 走的是整页 form POST 而非 XHR，只钩 XHR 会漏掉。
        document.addEventListener('submit', function(e) {
          try {
            var form = e.target;
            if (!form || form.tagName !== 'FORM') return;
            var pairs = [];
            var els = form.elements;
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              if (!el.name) continue;
              if ((el.type === 'checkbox' || el.type === 'radio') && !el.checked) continue;
              pairs.push(el.name + '=' + encodeURIComponent(el.value || ''));
            }
            record({
              via: 'form',
              method: (form.method || 'GET').toUpperCase(),
              url: form.action || location.href,
              headers: { 'Content-Type': form.enctype || 'application/x-www-form-urlencoded' },
              body: truncate(pairs.join('&'))
            });
          } catch (err) {}
        }, true);

        // ---- 钩 __doPostBack（WebForms 的常见触发入口）----
        var postBackHooked = false;
        function hookPostBack() {
          if (postBackHooked || typeof window.__doPostBack !== 'function') return;
          postBackHooked = true;
          var rawPostBack = window.__doPostBack;
          window.__doPostBack = function(target, argument) {
            record({ via: 'doPostBack', method: 'POST', url: location.href,
                     body: 'eventTarget=' + target + '&eventArgument=' + argument });
            return rawPostBack.apply(this, arguments);
          };
        }
        hookPostBack();
        document.addEventListener('DOMContentLoaded', hookPostBack);
      })();
    ''';
  }

  /// 生成导出脚本。
  ///
  /// 会递归遍历所有同源 frame 收集记录——单看主框架会漏掉 iframe 内的请求。
  /// [onlyWrites] 为 true 时只导出非 GET 请求，保存动作必定在其中。
  static String buildExportScript({bool onlyWrites = true}) {
    return '''
      (function() {
        var frames = [];

        function collect(win, path) {
          var out = [];
          var info = { path: path, hooked: false, url: null, error: null };
          try {
            info.url = win.location.href;
            var store = win.$storeName;
            info.hooked = !!store;
            if (store) {
              for (var i = 0; i < store.length; i++) {
                var entry = store[i];
                entry.framePath = path;
                out.push(entry);
              }
            }
            frames.push(info);
            for (var j = 0; j < win.frames.length; j++) {
              out = out.concat(collect(win.frames[j], path + '/' + j));
            }
          } catch (e) {
            // 跨域 iframe 不可读，记录下来便于诊断
            info.error = String(e);
            frames.push(info);
          }
          return out;
        }

        var all = collect(window, 'main');
        var list = all;
        ${onlyWrites ? "list = all.filter(function(e) { return (e.method || 'GET').toUpperCase() !== 'GET'; });" : ''}

        return JSON.stringify({
          total: all.length,
          exported: list.length,
          frames: frames,
          requests: list
        }, null, 2);
      })();
    ''';
  }

  /// 生成清空脚本，遍历所有同源 frame 一并清空。
  static String buildClearScript() {
    return '''
      (function() {
        var cleared = 0;
        function clear(win) {
          try {
            if (win.$storeName) { win.$storeName.length = 0; cleared++; }
            for (var i = 0; i < win.frames.length; i++) clear(win.frames[i]);
          } catch (e) {}
        }
        clear(window);
        return JSON.stringify({ clearedFrames: cleared });
      })();
    ''';
  }
}
