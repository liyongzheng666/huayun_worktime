import 'dart:convert';

import 'boss_session_script.dart';

/// 一个审核人候选是从哪来的。决定候选排序，也决定界面上怎么措辞。
enum BossAuditorSource {
  /// 个人设置 `WorkReport_AudtiorFocusor_defaultSetting`——最可信
  setting,

  /// 业务对象上名为 auditor / AUDITOR 的字段（历史日志等）
  field,
}

extension BossAuditorSourceLabel on BossAuditorSource {
  /// 给用户看的来源说明。措辞保守：除了个人设置，都不宣称「就是它」。
  String get label => switch (this) {
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

/// 从抓包响应里收集**所有能认出的审核人候选**
///
/// **为什么必须单独有这么一个东西**：审核人不在项目清单里。踩坑记录 3.21 已确认
/// 它是**个人设置**而不是项目属性——系统设置项
/// `WorkReport_AudtiorFocusor_defaultSetting` 存的就是当前用户的默认审核人
/// （注意 BOSS 自己把 Auditor 拼成了 `Audtior`，照抄即可，别顺手改对）。
///
/// 在此之前，审核人只能从 `WorkLogHistoryLookup` 顺带拿到，也就是说
/// **必须先在 BOSS 里填过一条日志**才能自动提交。
///
/// **为什么返回候选列表而不是「那一个」**：自动识别已经在真实使用中失败过两次。
/// 设置项在响应里以哪种形状出现，我们始终没有实测证据，再猜下去也只是换个姿势
/// 碰运气。而抓包里的 `USERINFO_` 大多带着姓名——**APP 分不清哪个是审核人、
/// 哪个是用户自己，但用户一眼就能认出来**。这和项目清单是同一个思路：
/// 别猜，把候选全列出来交给用户定。
///
/// **仍然绝不拿随便一个 `USERINFO_` 充数**：只收「挂在名字明确是审核人的键
/// 下面」的值，不做前缀碰运气式的扫描。个人设置扫到的排最前。
///
/// **只扫响应，不扫请求体**：BOSS 把明文 `Password` 放在每个请求体里
/// （踩坑记录 3.12）。输出也只有审核人 ID 与姓名。
class WorkLogAuditorLookup {
  WorkLogAuditorLookup._();

  /// 存默认审核人的系统设置项。BOSS 原文就是这个拼写。
  static const String settingKey = 'WorkReport_AudtiorFocusor_defaultSetting';

  /// 生成扫描脚本。
  ///
  /// 返回 JSON：
  /// `{"ok":true,"auditors":[{"id":";USERINFO_x","name":"姓名","source":"setting"}],"scanned":N}`
  static String build({required String captureStoreName}) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.walkPreamble()}

        var found = {};

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

        // 同一个人可能从多处扫到，按 ID 归并：来源就高不就低（设置项优先），
        // 姓名有则补上。否则候选列表里会出现两条看起来一样的。
        function take(id, name, isSetting) {
          var normalized = normalizeId(id);
          if (!normalized) return;

          var n = clean(name);
          // 姓名字段有时装的又是个 ID，那不是名字
          if (n.indexOf('USERINFO_') === 0) n = '';

          var prev = found[normalized];
          if (prev) {
            if (!prev.name && n) prev.name = n;
            if (isSetting) prev.source = 'setting';
            return;
          }
          found[normalized] = {
            id: normalized,
            name: n,
            source: isSetting ? 'setting' : 'field'
          };
        }

        // 键名里带 AudtiorFocusor 就认。除了 BOSS 现在这个拼写，
        // 也认拼写正确的那种——将来他们改回去不至于整条路又断掉。
        function isSettingKey(k) {
          return typeof k === 'string' &&
            (k.indexOf('AudtiorFocusor') >= 0 || k.indexOf('AuditorFocusor') >= 0);
        }

        // 设置项的值是一层 JSON 字符串：
        // {"auditor":";USERINFO_xxx","auditorText":"姓名"}
        function takeSettingValue(v) {
          if (typeof v === 'string') {
            try { v = JSON.parse(v); } catch (e) { return; }
          }
          if (!v || typeof v !== 'object') return;
          take(
            v.auditor || v.AUDITOR || v.Auditor,
            v.auditorText || v.auditorName || v.AuditorText,
            true
          );
        }

        function harvest(obj) {
          // —— 形状 1：设置项直接作为属性名挂在对象上 ——
          for (var k in obj) {
            if (obj.hasOwnProperty(k) && isSettingKey(k)) takeSettingValue(obj[k]);
          }
          // —— 形状 2：键值对。设置清单有好几种列名写法，都试一遍 ——
          if (isSettingKey(obj.Key)) takeSettingValue(obj.Value);
          if (isSettingKey(obj.SettingKey)) takeSettingValue(obj.SettingValue);
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

        var store = bossCaptured();
        for (var i = 0; i < store.length; i++) {
          var entry = store[i];
          // 只看响应：请求体里有明文凭据
          if (!entry || !entry.response) continue;
          bossWalk(entry.response, function(node) {
            if (!bossIsArray(node)) harvest(node);
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
  /// 排序：个人设置的排最前（它是「当前默认审核人」的权威出处），
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
            source: '${item['source']}' == 'setting'
                ? BossAuditorSource.setting
                : BossAuditorSource.field,
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
