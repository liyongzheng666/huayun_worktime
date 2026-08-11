import 'dart:convert';

import 'boss_session_script.dart';

/// BOSS 里的一个项目（名字 + 标识）
class BossProject {
  const BossProject({required this.id, required this.name});

  /// `PROJECT_xxxxxxxx`
  final String id;

  /// 项目中文名
  final String name;

  @override
  bool operator ==(Object other) =>
      other is BossProject && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'BossProject($name, $id)';
}

/// 从抓包响应里收集所有能认出的 BOSS 项目
///
/// **为什么不主动查一个「项目列表」接口**：BOSS 的列表接口是有状态视图，
/// 必须先由 `GetTitle` 在服务端建立查询上下文，单独调 `GetDataGridList`
/// 只会返回空行（实测 status 200、Rows 为空）。所以只能收割页面自己
/// 产生的响应——好在首页的「我的项目」网格在会话加载首页时就会返回，
/// 不需要用户额外操作。
///
/// **识别规则**：一处数据里同时出现「`PROJECT_` 开头的标识」和「一段不以
/// `PROJECT_` 开头的非空文本」，就认作一对（项目名, 项目 ID）。这条规则是
/// 自校验的——它天然排除了 `PROJECTCODE`（ColText 与 ColValue 都是
/// `PROJECT_` 开头，没有名字）和 `PROJECTID$DBValue`（ColValue 为 null）。
///
/// **只扫响应，不扫请求体**：BOSS 把明文 `Password` 放在每个请求体里
/// （见 docs/踩坑记录.md 3.12），扫请求体等于给凭据泄漏开一道口子。
/// 输出也只含项目名与 `PROJECT_` 标识，不含任何凭据。
class WorkLogProjectListLookup {
  WorkLogProjectListLookup._();

  /// 递归下探的层数上限。
  ///
  /// 响应是多层转义的 JSON，层数随接口而异；给足余量即可，
  /// 但必须封顶——BOSS 的响应里存在自引用结构，不封顶会栈溢出。
  static const int maxDepth = 12;

  /// 生成扫描脚本。
  ///
  /// 返回 JSON：`{"ok":true,"projects":[{"id":..,"name":..}],"scanned":N}`
  static String build({required String captureStoreName}) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}

        var MAX_DEPTH = $maxDepth;
        var found = {};

        // 收下一对 (名字, ID)。两个方向都试，因为同一列里
        // 谁是标识、谁是名字并不固定。
        function addPair(name, id) {
          if (typeof name !== 'string' || typeof id !== 'string') return;
          if (id.indexOf('PROJECT_') !== 0) return;

          var n = name.replace(/^\\s+|\\s+\$/g, '');
          if (!n) return;
          // 名字本身又是个标识，说明这一列没有可读的项目名
          if (n.indexOf('PROJECT_') === 0 || n.indexOf('USERINFO_') === 0) return;

          found[id + '\\u0000' + n] = { id: id, name: n };
        }

        function harvest(obj) {
          // 网格列对象形状：{ColName, ColText, ColValue}
          if (typeof obj.ColName === 'string') {
            addPair(obj.ColText, obj.ColValue);
            addPair(obj.ColValue, obj.ColText);
            return;
          }
          // 详情形状：一条记录上直接带 PROJECTID / PROJECTNAME
          addPair(obj.PROJECTNAME, obj.PROJECTID);
        }

        function walk(node, depth) {
          if (node === null || node === undefined || depth > MAX_DEPTH) return;

          if (typeof node === 'string') {
            // 可能是又一层转义的 JSON，试着再解一层
            var head = node.charAt(0);
            if ((head === '{' || head === '[') && node.length > 2) {
              try { walk(JSON.parse(node), depth + 1); } catch (e) {}
            }
            return;
          }

          if (typeof node !== 'object') return;

          if (Object.prototype.toString.call(node) === '[object Array]') {
            for (var i = 0; i < node.length; i++) walk(node[i], depth + 1);
            return;
          }

          harvest(node);
          for (var k in node) {
            if (node.hasOwnProperty(k)) walk(node[k], depth + 1);
          }
        }

        var store = bossCaptured();
        for (var i = 0; i < store.length; i++) {
          var entry = store[i];
          // 只看响应：请求体里有明文 Password
          if (!entry || !entry.response) continue;
          walk(entry.response, 0);
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
  /// 同名同 ID 的重复项在脚本里已按 key 去重，这里只做类型收敛与排序。
  /// 按名字排序是为了让候选列表的顺序稳定——抓包顺序会随用户的浏览行为变，
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
        projects.add(BossProject(id: id, name: name));
      }

      projects.sort((a, b) => a.name.compareTo(b.name));
      return projects;
    } catch (e) {
      return const [];
    }
  }
}
