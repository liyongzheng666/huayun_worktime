import 'dart:convert';

import 'boss_session_script.dart';

/// 一个审核人候选是从哪来的。决定候选排序，也决定界面上怎么措辞。
enum BossAuditorSource {
  /// 网页当前使用的 GetWorkLogAuditor 查询结果
  service,

  /// 个人设置 `WorkReport_AudtiorFocusor_defaultSetting`
  setting,

  /// 业务对象上名为 auditor / AUDITOR 的字段（历史日志等）
  field,
}

extension BossAuditorSourceLabel on BossAuditorSource {
  /// 给用户看的来源说明。措辞保守：除了个人设置，都不宣称「就是它」。
  String get label => switch (this) {
    BossAuditorSource.service => 'BOSS 当前审核人',
    BossAuditorSource.setting => '你的默认审核人设置',
    BossAuditorSource.field => '出现在日志的审核人字段里',
  };
}

/// 工作日志的审核人
class BossAuditor {
  const BossAuditor({
    required this.id,
    this.name = '',
    this.source = BossAuditorSource.field,
  });

  /// 提交报文里的 `AUDITOR`，统一带前导分号，形如 `;USERINFO_xxx`
  final String id;

  /// 审核人姓名，只用于让用户在提交前肉眼核对
  final String name;

  /// 这条候选是从哪扫到的
  final BossAuditorSource source;

  @override
  bool operator ==(Object other) =>
      other is BossAuditor &&
      other.id == id &&
      other.name == name &&
      other.source == source;

  @override
  int get hashCode => Object.hash(id, name, source);

  @override
  String toString() => 'BossAuditor($name, $id, ${source.name})';
}

/// 从网页当前审核人服务、个人设置和抓包响应收集审核人候选
///
/// **为什么必须单独有这么一个东西**：审核人不在项目清单里。踩坑记录 3.21 已确认
/// 网页现在优先调用 `GetWorkLogAuditor`，并传入当前项目；系统设置项
/// `WorkReport_AudtiorFocusor_defaultSetting` 存的就是当前用户的默认审核人
/// 可作兜底（注意 BOSS 自己把 Auditor 拼成了 `Audtior`，照抄即可）。
///
/// 在此之前，审核人只能从 `WorkLogHistoryLookup` 顺带拿到，也就是说
/// **必须先在 BOSS 里填过一条日志**才能自动提交。
///
/// **为什么返回候选列表而不是「那一个」**：自动识别已经在真实使用中失败过两次。
/// 网页服务可能返回多个审核人；旧设置与历史日志也可能不同。因此保留来源，
/// 让提交服务只在当前查询结果唯一时自动使用，其余交给用户核对。
///
/// **仍然绝不拿随便一个 `USERINFO_` 充数**：只收「挂在名字明确是审核人的键
/// 下面」的值，不做前缀碰运气式的扫描。专用查询结果排最前。
///
/// **抓包只扫响应，不扫请求体**：BOSS 把明文 `Password` 放在每个请求体里
/// （踩坑记录 3.12）。输出也只有审核人 ID 与姓名。
class WorkLogAuditorLookup {
  WorkLogAuditorLookup._();

  /// 存默认审核人的系统设置项。BOSS 原文就是这个拼写。
  static const String settingKey = 'WorkReport_AudtiorFocusor_defaultSetting';

  /// 生成扫描脚本。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"auditors":[{"id":";USERINFO_x","name":"姓名","source":"setting"}],"scanned":N}`
  static String build({
    required String captureStoreName,
    String projectId = '',
  }) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.walkPreamble()}

        var found = {};
        var PROJECT_ID = ${jsonEncode(projectId)};
        var SETTING_KEY = ${jsonEncode(settingKey)};

        // 报文里的 AUDITOR 带前导分号，设置项里也带；统一补齐，
        // 免得两个来源出来的值一个带一个不带，提交时形状不一致。
        function normalizeId(v) {
          if (typeof v !== 'string') return '';
          var s = v.replace(/^\\s+|\\s+\$/g, '');
          if (s.charAt(0) === ';') s = s.substring(1);
          if (s.indexOf('USERINFO_') !== 0) return '';
          return ';' + s;
        }

        function clean(v) {
          return typeof v === 'string' ? v.replace(/^\\s+|\\s+\$/g, '') : '';
        }

        // 同一个人可能从多处扫到，按 ID 归并：当前查询优先于设置和历史，
        // 姓名有则补上。否则候选列表里会出现两条看起来一样的。
        function take(id, name, isSetting, isService) {
          var normalized = normalizeId(id);
          if (!normalized) return;

          var n = clean(name);
          // 姓名字段有时装的又是个 ID，那不是名字
          if (normalizeId(n)) n = '';

          var prev = found[normalized];
          if (prev) {
            if (!prev.name && n) prev.name = n;
            if (isService) {
              prev.source = 'service';
              if (n) prev.name = n;
            } else if (isSetting && prev.source !== 'service') {
              prev.source = 'setting';
            }
            return;
          }
          found[normalized] = {
            id: normalized,
            name: n,
            source: isService ? 'service' : (isSetting ? 'setting' : 'field')
          };
        }

        // 键名里带 AudtiorFocusor 就认。除了 BOSS 现在这个拼写，
        // 也认拼写正确的那种——将来他们改回去不至于整条路又断掉。
        function isSettingKey(k) {
          return typeof k === 'string' &&
            (k.indexOf('AudtiorFocusor') >= 0 || k.indexOf('AuditorFocusor') >= 0);
        }

        // 设置值也会被多层 JSON 或响应对象包装；解包时必须保留设置来源。
        function takeSettingValue(value) {
          function step(v, depth) {
            if (!v || depth > 12) return;
            if (typeof v === 'string') {
              try { step(JSON.parse(v), depth + 1); } catch (e) {}
              return;
            }
            if (typeof v !== 'object') return;
            take(
              v.auditor || v.AUDITOR || v.Auditor,
              v.auditorText || v.auditorName || v.AuditorText,
              true
            );
            for (var k in v) {
              if (v.hasOwnProperty(k)) step(v[k], depth + 1);
            }
          }
          step(value, 0);
        }

        // 姓名与原始 ID 可能分在 AUDITOR / AUDITOR\$DBValue 两列。
        // 只合并当前行，不能把相邻日志的姓名拼到这个 ID 上。
        function harvestRow(row) {
          var display = null;
          var raw = null;
          for (var i = 0; i < row.length; i++) {
            var col = row[i];
            if (!col || typeof col !== 'object') continue;
            if (col.ColName === 'AUDITOR') display = col;
            if (col.ColName === 'AUDITOR\$DBValue') raw = col;
          }
          display = display || {};
          raw = raw || {};
          var id = normalizeId(display.ColValue) || normalizeId(display.ColText) ||
            normalizeId(raw.ColValue) || normalizeId(raw.ColText);
          var name = clean(display.ColText);
          if (!name || normalizeId(name)) name = clean(display.ColValue);
          take(id, name, false);
        }

        function harvest(obj) {
          // —— 形状 1：设置项直接作为属性名挂在对象上 ——
          for (var k in obj) {
            if (obj.hasOwnProperty(k) && isSettingKey(k)) takeSettingValue(obj[k]);
          }
          // —— 形状 2：键值对。设置清单有好几种列名写法，都试一遍 ——
          if (isSettingKey(obj.Key)) takeSettingValue(obj.Value);
          if (isSettingKey(obj.SettingKey)) takeSettingValue(obj.SettingValue);
          // BOSS 的 SystemSettings 实际使用这组字段。
          if (isSettingKey(obj.ENAME)) takeSettingValue(obj.SETTINGVALUE);
          if (isSettingKey(obj.ColName)) {
            takeSettingValue(obj.ColValue);
            takeSettingValue(obj.ColText);
          }
          // —— 形状 3：对象上直接带 auditor 字段（历史日志详情等）——
          //
          // 只认键名本身就是审核人的字段，不做前缀扫描：
          // 抓包里的 USERINFO_ 大多是用户自己。
          if (typeof obj.auditor === 'string') {
            take(obj.auditor, obj.auditorText || obj.auditorName, false);
          }
          if (typeof obj.AUDITOR === 'string') {
            take(obj.AUDITOR, obj.AUDITORNAME || obj.AuditorName, false);
          }
          // —— 形状 4：网格里的 AUDITOR 列，ID 在 ColValue、姓名在 ColText ——
          //
          // 历史日志网格就是这样（踩坑记录里那三行实测数据）。
          // 之前漏了这一形状，而它恰恰是最容易抓到的一种。
          if (obj.ColName === 'AUDITOR' || obj.ColName === 'AUDITOR\$DBValue') {
            take(obj.ColValue, obj.ColText, false);
            take(obj.ColText, obj.ColValue, false);
          }
        }

        // 与网页相同：个人设置从内存读取，审核人从专用只读服务查询。
        // 只选一个同源 frame 发请求，避免门户各 frame 重复查询。
        var serviceUi = null;
        function readPage(win, depth) {
          if (depth > 12) return;
          try {
            var ui = win.HoteamUI;
            if (ui) {
              if (!serviceUi && ui.DataService &&
                  typeof ui.DataService.Call === 'function') serviceUi = ui;
              if (ui.Common && typeof ui.Common.GetPersonalSetting === 'function') {
                try { takeSettingValue(ui.Common.GetPersonalSetting(SETTING_KEY)); }
                catch (e) {}
              }
            }
            for (var i = 0; i < win.frames.length; i++) readPage(win.frames[i], depth + 1);
          } catch (e) {}
        }
        readPage(window, 0);

        function readCurrentAuditors(projectId) {
          var para = {UseLast: true};
          if (projectId) para.ProjectID = projectId;
          try {
            var list = serviceUi.DataService.Call(
              'Hoteam.InforCenter.WorkReportService.GetWorkLogAuditor', {para: para});
            if (!bossIsArray(list)) return;
            for (var i = 0; i < list.length; i++) {
              var item = list[i];
              if (item && typeof item === 'object') take(item.Value, item.Text, false, true);
            }
          } catch (e) {}
        }
        if (serviceUi) {
          readCurrentAuditors('');
          if (PROJECT_ID) readCurrentAuditors(PROJECT_ID);
        }

        var store = bossCaptured();
        for (var i = 0; i < store.length; i++) {
          var entry = store[i];
          // 只看响应：请求体里有明文凭据
          if (!entry || !entry.response) continue;
          bossWalk(entry.response, function(node) {
            if (bossIsArray(node)) harvestRow(node);
            else harvest(node);
          });
        }

        var auditors = [];
        for (var key in found) {
          if (found.hasOwnProperty(key)) auditors.push(found[key]);
        }

        return JSON.stringify({
          ok: true,
          auditors: auditors,
          scanned: store.length
        });
      })();
    ''';
  }

  /// 解析脚本返回值；解析不了时返回空列表（「没扫到」而非报错）。
  ///
  /// 排序：当前服务结果最前，个人设置其次，历史字段最后；
  /// 其次是有姓名的（没名字的没法核对，排后面），最后按姓名排，保证顺序稳定。
  static List<BossAuditor> parse(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return const [];

      final list = decoded['auditors'];
      if (list is! List) return const [];

      final auditors = <BossAuditor>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        if (!id.startsWith(';USERINFO_')) continue;
        auditors.add(
          BossAuditor(
            id: id,
            name: '${item['name'] ?? ''}',
            source: switch (item['source']) {
              'service' => BossAuditorSource.service,
              'setting' => BossAuditorSource.setting,
              _ => BossAuditorSource.field,
            },
          ),
        );
      }

      auditors.sort((a, b) {
        final bySource = a.source.index.compareTo(b.source.index);
        if (bySource != 0) return bySource;
        final byNamed = (b.name.isNotEmpty ? 1 : 0).compareTo(
          a.name.isNotEmpty ? 1 : 0,
        );
        if (byNamed != 0) return byNamed;
        return a.name.compareTo(b.name);
      });
      return auditors;
    } catch (e) {
      return const [];
    }
  }
}
