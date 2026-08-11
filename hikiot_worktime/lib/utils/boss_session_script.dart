/// BOSS 网页会话脚本的公共片段
///
/// **为什么要单独抽这个类**：找会话上下文（`findPara`）和「克隆 para → 换
/// ServiceUri → POST DataService → 逐层解开响应」这两段，原先在提交、会话探测、
/// 取常量、单日工时、整月工时五处各抄了一遍。后果是同一个 BUG 要改五次，
/// 而实际上都漏改过：
///
/// - 会话筛选条件误加 `ServiceUri`（踩坑记录 3.11）——只修了四处，漏了整月工时；
/// - 抓包记录只读主框架（踩坑记录 2.7）——六处**全部**漏改，而这正是
///   「自动获取项目信息」屡试屡败的真正原因：业务模块跑在 iframe 里，
///   抓包钩子在每个 frame 各存一份，只读主框架拿到的永远只有首页自身的请求。
///
/// 按项目「再一再而不再三」原则收口到这里，调用方只拼业务部分。
///
/// **安全约定**：这里只负责就地复用网页会话，不导出、不持久化 `para`。
/// BOSS 把 `Password` 明文放在每个业务请求体里，把会话上下文存进 APP
/// 等同于本地明文保存登录凭据（踩坑记录 3.12）。
class BossSessionScript {
  BossSessionScript._();

  /// BOSS 所有业务服务的统一入口。
  static const String dataServicePath = '/Base/BaseService.asmx/DataService';

  /// 会话相关的 JS 函数定义，调用方嵌到自己脚本的开头即可。
  ///
  /// 提供两个函数：
  /// - `bossCaptured()` → 所有同源 frame 的抓包记录，按抓取时间升序（最新在末尾）
  /// - `bossFindPara()` → 最近一条带 `UserID` 的 para，找不到返回 null
  ///
  /// 与 [callPreamble] 分开是有意的：只读抓包的脚本（会话探测、提取常量）
  /// 不该夹带一个它永远不会用到的 XHR 发送函数，
  /// 「会话查找不得依赖 ServiceUri」这条约束也才能被测试直接验证。
  static String sessionPreamble({required String captureStoreName}) {
    return '''
      // —— 汇总所有同源 frame 的抓包记录 ——
      //
      // 必须递归遍历 window.frames：BOSS 是门户型系统，业务模块跑在 iframe 里，
      // 抓包钩子以 forMainFrameOnly:false 注入后在每个 frame 各存一份。
      // 只读主框架的话，拿到的永远只有首页自身那几十个请求，
      // 真正需要的列表 / 详情 / 保存报文一条都看不到。
      function bossCaptured() {
        var out = [];
        function walk(win) {
          try {
            var store = win.$captureStoreName;
            if (store) {
              for (var i = 0; i < store.length; i++) out.push(store[i]);
            }
            for (var j = 0; j < win.frames.length; j++) walk(win.frames[j]);
          } catch (e) {
            // 跨域 frame 不可读，跳过即可
          }
        }
        walk(window);

        // 各 frame 的记录在时间上是交错的，直接拼接会打乱先后。
        // 按抓取时刻排序，调用方才能靠「从后往前」取到真正最新的一条。
        out.sort(function(a, b) {
          var x = (a && a.at) || '';
          var y = (b && b.at) || '';
          return x < y ? -1 : (x > y ? 1 : 0);
        });
        return out;
      }

      // —— 取会话上下文 ——
      //
      // 只用 UserID 判断：ServiceUri 是我们自己要设进去的值，
      // 拿它当筛选条件是逻辑错误。登录后首页自动发的
      // CheckUserUnReadMessage / GetIntervals 都不带 ServiceUri，
      // 但 para 是完整的——要求它会让刚登录时取不到会话。
      function bossFindPara() {
        var store = bossCaptured();
        for (var i = store.length - 1; i >= 0; i--) {
          var entry = store[i];
          if (!entry || !entry.body) continue;
          try {
            var parsed = JSON.parse(entry.body);
            if (parsed && parsed.para && parsed.para.UserID) return parsed.para;
          } catch (e) {}
        }
        return null;
      }
    ''';
  }

  /// 业务请求发送函数 `bossCall(para, serviceUri, innerFields)`。
  ///
  /// 返回 `{ok:true, data, text}`，失败时返回 `{ok:false, reason, ...}`。
  /// 需要配合 [sessionPreamble] 使用（para 由 `bossFindPara()` 提供）。
  static String callPreamble() {
    return '''
      // —— 发一次业务请求 ——
      //
      // 报文形状固定为 {para: 外层, content: JSON({para: 内层})}：
      // 外层带 ServiceUri 指明调哪个服务，内层带同样的会话上下文加业务字段。
      // 用同步 XHR 是为了把结果直接返回给 evaluateJavascript。
      function bossCall(para, serviceUri, innerFields) {
        var outer = {};
        for (var k in para) {
          if (para.hasOwnProperty(k)) outer[k] = para[k];
        }
        outer.ServiceUri = serviceUri;

        var inner = {};
        for (var k2 in para) {
          if (para.hasOwnProperty(k2)) inner[k2] = para[k2];
        }
        delete inner.ServiceUri;
        for (var k3 in innerFields) {
          if (innerFields.hasOwnProperty(k3)) inner[k3] = innerFields[k3];
        }

        var xhr = new XMLHttpRequest();
        xhr.open('POST', ${_quote(dataServicePath)}, false);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

        try {
          xhr.send(JSON.stringify({
            para: outer,
            content: JSON.stringify({ para: inner })
          }));
        } catch (e) {
          return { ok: false, reason: 'network', message: String(e) };
        }

        if (xhr.status !== 200) {
          return {
            ok: false,
            reason: 'http',
            status: xhr.status,
            message: (xhr.responseText || '').substring(0, 300)
          };
        }

        // 响应是多层转义的 JSON 字符串（外层 d 里再包一层 d），需要逐层解开
        var text = xhr.responseText || '';
        var data = null;
        try {
          var lvl1 = JSON.parse(text).d;
          data = (typeof lvl1 === 'string') ? JSON.parse(lvl1).d : lvl1;
        } catch (e) {}

        return { ok: true, data: data, text: text };
      }
    ''';
  }

  /// 网格响应的解包工具。
  ///
  /// BOSS 的列表类响应统一是「多层转义的 JSON 里包一个 Rows 网格」，
  /// 每行是一组 `{ColName, ColText, ColValue}` 列对象。历史日志查询和
  /// 项目清单扫描都要拆它，因此收在这里共用。
  ///
  /// **同一列里谁是标识并不固定**：`PROJECTID` 列的 ID 在 `ColValue`、
  /// 项目名反而在 `ColText`，而伴生列 `PROJECTID$DBValue` 的 ID 在 `ColText`。
  /// 所以 [pickId] 两边都试，以前缀判定谁才是真正的标识。
  static String gridPreamble() {
    return '''
      // 响应是多层转义的 JSON，逐层解开后取出网格对象
      function unwrapGrid(text) {
        try {
          var lvl1 = JSON.parse(text).d;
          var lvl2 = (typeof lvl1 === 'string') ? JSON.parse(lvl1) : lvl1;
          var grid = (lvl2 && lvl2.d !== undefined) ? lvl2.d : lvl2;
          return (grid && grid.Rows && grid.Rows.length) ? grid : null;
        } catch (e) {
          return null;
        }
      }

      // 一行 = 一组列对象，转成 列名 -> {text, value} 便于按名取值
      function rowMap(row) {
        var map = {};
        for (var i = 0; i < row.length; i++) {
          var col = row[i];
          if (!col || !col.ColName) continue;
          map[col.ColName] = { text: col.ColText, value: col.ColValue };
        }
        return map;
      }

      // 取某列符合前缀的那个值，ColValue / ColText 两边都试
      function pickId(map, colName, prefix) {
        var names = [colName, colName + '\$DBValue'];
        for (var n = 0; n < names.length; n++) {
          var col = map[names[n]];
          if (!col) continue;
          var candidates = [col.value, col.text];
          for (var c = 0; c < candidates.length; c++) {
            var v = candidates[c];
            if (typeof v === 'string' && v.indexOf(prefix) === 0) return v;
          }
        }
        return '';
      }
    ''';
  }

  /// 响应的深度遍历工具 `bossWalk(node, visit)`。
  ///
  /// BOSS 的响应是**多层转义**的 JSON：外层解开之后，里面的字符串往往又是一段
  /// JSON。想从响应里捞任何东西，都得一边下探一边试着再解一层。项目清单扫描和
  /// 审核人扫描都要这么走，按「再一再而不再三」收口到这里。
  ///
  /// `visit(node)` 对遍历到的每个**对象和数组**各调用一次；数组要不要单独处理
  /// 由调用方判断（网格的一行就是数组，列分散在各元素里，必须整行一起看）。
  ///
  /// **必须封顶**：不封深度的话，遇到自引用结构会直接栈溢出。
  static String walkPreamble({int maxDepth = 12}) {
    return '''
      function bossWalk(node, visit) {
        var MAX_DEPTH = $maxDepth;
        function step(n, depth) {
          if (n === null || n === undefined || depth > MAX_DEPTH) return;

          if (typeof n === 'string') {
            // 可能是又一层转义的 JSON，试着再解一层
            var head = n.charAt(0);
            if ((head === '{' || head === '[') && n.length > 2) {
              try { step(JSON.parse(n), depth + 1); } catch (e) {}
            }
            return;
          }

          if (typeof n !== 'object') return;

          visit(n);

          if (Object.prototype.toString.call(n) === '[object Array]') {
            for (var i = 0; i < n.length; i++) step(n[i], depth + 1);
            return;
          }
          for (var k in n) {
            if (n.hasOwnProperty(k)) step(n[k], depth + 1);
          }
        }
        step(node, 0);
      }

      function bossIsArray(n) {
        return Object.prototype.toString.call(n) === '[object Array]';
      }
    ''';
  }

  /// 生成「未捕获到会话」的统一返回值，各脚本提示文案保持一致。
  static const String noSessionResult =
      '''JSON.stringify({
          ok: false,
          reason: 'noSession',
          message: '未捕获到会话上下文，请先在页面上做一次任意操作（如切换日期）'
        })''';

  /// JS 字符串字面量，避免调用方为了转义再引一次 dart:convert。
  static String _quote(String value) => "'${value.replaceAll("'", r"\'")}'";
}
