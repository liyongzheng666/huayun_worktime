import 'dart:convert';

import 'boss_session_script.dart';

/// 工作日志的审核人
class BossAuditor {
  const BossAuditor({required this.id, this.name = ''});

  /// 提交报文里的 `AUDITOR`，统一带前导分号，形如 `;USERINFO_xxx`
  final String id;

  /// 审核人姓名，只用于让用户在提交前肉眼核对
  final String name;

  @override
  bool operator ==(Object other) =>
      other is BossAuditor && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'BossAuditor($name, $id)';
}

/// 从抓包响应里读取当前用户的**默认审核人**
///
/// **为什么必须单独有这么一个东西**：审核人不在项目清单里。踩坑记录 3.21 已确认
/// 它是**个人设置**而不是项目属性——系统设置项
/// `WorkReport_AudtiorFocusor_defaultSetting` 存的就是当前用户的默认审核人
/// （注意 BOSS 自己把 Auditor 拼成了 `Audtior`，照抄即可，别顺手改对）。
///
/// 在此之前，审核人只能从 `WorkLogHistoryLookup` 顺带拿到，也就是说
/// **必须先在 BOSS 里填过一条日志**才能自动提交。而项目清单登录后就能扫到全量，
/// 于是出现一种很别扭的失败：项目明明扫得到、用户也认得出是哪个，却因为凑不齐
/// 审核人而整条路走不通。把审核人拆出来单独取，这条路才通。
///
/// **绝不拿随便一个 `USERINFO_` 充数**：抓包里别处出现的 `USERINFO_` 往往是
/// 用户**自己**的 ID，认错了会把日志提交给错误的审批人。因此这里只认
/// 「挂在名字明确是审核人的键下面」的值，不做任何前缀碰运气式的扫描。
///
/// **只扫响应，不扫请求体**：BOSS 把明文 `Password` 放在每个请求体里
/// （踩坑记录 3.12）。输出也只有审核人 ID 与姓名。
class WorkLogAuditorLookup {
  WorkLogAuditorLookup._();

  /// 存默认审核人的系统设置项。BOSS 原文就是这个拼写。
  static const String settingKey = 'WorkReport_AudtiorFocusor_defaultSetting';

  /// 生成扫描脚本。
  ///
  /// 返回 JSON：`{"ok":true,"id":";USERINFO_xxx","name":"姓名","source":"setting"|"field"}`；
  /// 没扫到时 `ok:false`。
  static String build({required String captureStoreName}) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.walkPreamble()}

        // 来自个人设置的最可信，是「当前默认审核人」的权威出处；
        // 带 auditor 字段的业务对象（历史日志详情等）作为兜底。
        var fromSetting = null;
        var fromField = null;

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

        function take(id, name, isSetting) {
          var normalized = normalizeId(id);
          if (!normalized) return;
          var hit = { id: normalized, name: clean(name) };
          if (isSetting) {
            // 同一个设置项可能被多个响应带出来，取第一个即可；
            // 但姓名可能只在其中一份里有，缺了就补上
            if (!fromSetting) fromSetting = hit;
            else if (!fromSetting.name && hit.name) fromSetting.name = hit.name;
            return;
          }
          if (!fromField) fromField = hit;
          else if (!fromField.name && hit.name) fromField.name = hit.name;
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

        var hit = fromSetting || fromField;
        if (!hit) {
          return JSON.stringify({
            ok: false,
            reason: 'noAuditor',
            scanned: store.length,
            message: '抓包里没有审核人设置'
          });
        }

        return JSON.stringify({
          ok: true,
          id: hit.id,
          name: hit.name,
          source: fromSetting ? 'setting' : 'field',
          scanned: store.length
        });
      })();
    ''';
  }

  /// 解析脚本返回值；解析不了或没扫到时返回 null（「没取到」而非报错）。
  static BossAuditor? parse(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return null;

      final id = '${decoded['id'] ?? ''}';
      if (!id.startsWith(';USERINFO_')) return null;

      return BossAuditor(id: id, name: '${decoded['name'] ?? ''}');
    } catch (e) {
      return null;
    }
  }
}
