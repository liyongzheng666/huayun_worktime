import 'dart:convert';

import 'boss_session_script.dart';

/// BOSS 里的一个项目
class BossProject {
  const BossProject({required this.id, required this.name, this.code = ''});

  /// 项目的 `EID`，提交日志时作为 `PROJECTID`
  final String id;

  /// 项目中文名
  final String name;

  /// 项目的 `EUID`，提交日志时作为 `PROJECTCODE`；扫不到时为空串
  final String code;

  @override
  bool operator ==(Object other) =>
      other is BossProject &&
      other.id == id &&
      other.name == name &&
      other.code == code;

  @override
  int get hashCode => Object.hash(id, name, code);

  @override
  String toString() => 'BossProject($name, $id, $code)';
}

/// 从抓包响应里收集所有能认出的 BOSS 项目
///
/// **为什么不主动查一个「项目列表」接口**：BOSS 的列表接口是有状态视图，
/// 必须先由 `GetTitle` 在服务端建立查询上下文，单独调 `GetDataGridList`
/// 只会返回空行（实测 status 200、Rows 为空）。所以只能收割页面自己
/// 产生的响应——好在**首页登录后就会自动发
/// `InforCenter.Project.ProjectPortalService.GetMyJoinProjectGrid`**，
/// 里面是「我参与的项目」全量列表，不需要用户额外操作。
///
/// **`PROJECTID` 是项目的 `EID`，`PROJECTCODE` 是项目的 `EUID`**——由实际
/// 抓包比对确认（日志 PROJECTID/PROJECTCODE 与项目对象的 EID/EUID 逐字相同）。
/// 因此从项目网格一次就能拿到提交所需的完整三元组。
///
/// **必须认四种形状**，都是实际抓包里出现过的：
/// 1. 行内分列：`ColName:"EID"` 与 `ColName:"ENAME"` 是**同一行里不同的列对象**
///    （我的项目网格）。早期只认「同一列对象内的 ColText/ColValue 配对」，
///    整个网格一条都扫不到。
/// 2. 同列配对：`ColName:"PROJECTNAME", ColText:中文名, ColValue:PROJECT_xxx`
///    （历史日志网格）
/// 3. 键值对：`{Key:"PROJECT_xxx", Value:"中文名"}`（项目下拉的数据源
///    `GetMyJoinProjectListbyYssj`）
/// 4. 详情对象：同一对象上带 `PROJECTID` 与 `PROJECTNAME`
///
/// **只扫响应，不扫请求体**：BOSS 把明文 `Password` 放在每个请求体里
/// （见 docs/踩坑记录.md 3.12）。输出也只含项目名与 `PROJECT_` 标识。
class WorkLogProjectListLookup {
  WorkLogProjectListLookup._();

  /// 递归下探的层数上限。
  ///
  /// 响应是多层转义的 JSON，层数随接口而异；给足余量即可，
  /// 但必须封顶——不封顶遇到自引用结构会栈溢出。
  static const int maxDepth = 12;

  /// 生成扫描脚本。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"projects":[{"id":..,"name":..,"code":..}],"scanned":N}`
  static String build({required String captureStoreName}) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.walkPreamble(maxDepth: maxDepth)}

        var found = {};

        function clean(v) {
          if (typeof v !== 'string') return '';
          return v.replace(/^\\s+|\\s+\$/g, '');
        }

        function isProjectId(v) {
          return typeof v === 'string' && v.indexOf('PROJECT_') === 0;
        }

        // 收下一个项目。名字必须是可读文本，不能又是个标识。
        //
        // 同一个项目可能从多个响应里扫到，其中只有部分带 code；
        // 按 id 归并并补齐 code，避免「有名字没编码」和「有编码没名字」
        // 各占一条，让候选列表里出现两个看起来一样的项目。
        function addProject(name, id, code) {
          if (!isProjectId(id)) return;

          var n = clean(name);
          if (!n || n.indexOf('PROJECT_') === 0 || n.indexOf('USERINFO_') === 0) return;

          var c = isProjectId(code) && code !== id ? code : '';
          var prev = found[id];
          if (prev) {
            if (!prev.code && c) prev.code = c;
            return;
          }
          found[id] = { id: id, name: n, code: c };
        }

        // —— 形状 1：一行网格，列分散在各自的列对象里 ——
        //
        // 我的项目网格就是这样：EID 在一列、ENAME 在另一列、EUID 在第三列，
        // 必须整行一起看才能配上。
        function harvestRow(arr) {
          var map = {};
          var isRow = false;
          for (var i = 0; i < arr.length; i++) {
            var col = arr[i];
            if (!col || typeof col !== 'object') continue;
            if (typeof col.ColName !== 'string') continue;
            isRow = true;
            map[col.ColName] = col;
          }
          if (!isRow) return;

          // 同一列里标识可能在 ColText 也可能在 ColValue，两边都试
          function pickId(names) {
            for (var k = 0; k < names.length; k++) {
              var col = map[names[k]];
              if (!col) continue;
              if (isProjectId(col.ColValue)) return col.ColValue;
              if (isProjectId(col.ColText)) return col.ColText;
            }
            return '';
          }
          function pickName(names) {
            for (var k = 0; k < names.length; k++) {
              var col = map[names[k]];
              if (!col) continue;
              var t = clean(col.ColText);
              if (t && !isProjectId(t)) return t;
            }
            return '';
          }

          addProject(
            pickName(['ENAME', 'PROJECTNAME']),
            pickId(['EID', 'PROJECTID']),
            pickId(['EUID', 'PROJECTCODE'])
          );
        }

        function harvest(obj) {
          // —— 形状 2：同一个列对象里 ColText / ColValue 配成一对 ——
          if (typeof obj.ColName === 'string') {
            addProject(obj.ColText, obj.ColValue, '');
            addProject(obj.ColValue, obj.ColText, '');
            return;
          }
          // —— 形状 3：键值对（项目下拉的数据源）——
          if (typeof obj.Key === 'string' && typeof obj.Value === 'string') {
            addProject(obj.Value, obj.Key, '');
            addProject(obj.Key, obj.Value, '');
            return;
          }
          // —— 形状 4：详情对象上直接带 PROJECTID / PROJECTNAME ——
          if (typeof obj.PROJECTID === 'string') {
            addProject(obj.PROJECTNAME, obj.PROJECTID, obj.PROJECTCODE);
          }
        }

        var store = bossCaptured();
        for (var i = 0; i < store.length; i++) {
          var entry = store[i];
          // 只看响应：请求体里有明文凭据
          if (!entry || !entry.response) continue;
          // 数组要单独走 harvestRow：网格的一行就是个数组，
          // EID / ENAME / EUID 分散在各元素里，必须整行一起看
          bossWalk(entry.response, function(node) {
            if (bossIsArray(node)) harvestRow(node);
            else harvest(node);
          });
        }

        var projects = [];
        for (var key in found) {
          if (found.hasOwnProperty(key)) projects.push(found[key]);
        }

        return JSON.stringify({
          ok: true,
          projects: projects,
          scanned: store.length
        });
      })();
    ''';
  }

  /// 解析脚本返回值；解析不了时返回空列表（「没扫到」而非报错）。
  ///
  /// 按名字排序让候选列表顺序稳定——抓包顺序会随浏览行为变，
  /// 每次弹出来顺序都不一样的列表没法建立肌肉记忆。
  static List<BossProject> parse(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return const [];

      final list = decoded['projects'];
      if (list is! List) return const [];

      final projects = <BossProject>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        final name = '${item['name'] ?? ''}';
        if (id.isEmpty || name.isEmpty) continue;
        projects.add(
          BossProject(id: id, name: name, code: '${item['code'] ?? ''}'),
        );
      }

      projects.sort((a, b) => a.name.compareTo(b.name));
      return projects;
    } catch (e) {
      return const [];
    }
  }
}
