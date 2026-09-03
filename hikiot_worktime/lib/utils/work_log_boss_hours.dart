import 'dart:convert';

import 'boss_session_script.dart';

/// BOSS 已填工时抓取
///
/// 用途：月历页除了展示海康打卡工时，还要展示 BOSS 系统里已填报的工时，
/// 便于一眼看出「打了卡但没填日志」或「填报工时和打卡对不上」；
/// 提交前也用它检查当天是否已有日志。
///
/// 数据来源：`Hoteam.InforCenter.WorkReportService.GetWorkHours`，
/// 传 `SelectDate` 返回 `[总额度, 已填, 剩余]`，取中间值即当日已填工时。
///
/// 为什么在 WebView 里跑而不在 Dart 里直接请求：BOSS 把 `Password` 放在
/// 每个请求体里，要在 Dart 侧发请求就必须先把凭据存到本地。
/// 复用网页会话可以完全避免这一点。
class WorkLogBossHours {
  WorkLogBossHours._();

  static const String hoursServiceUri =
      'Hoteam.InforCenter.WorkReportService.GetWorkHours';

  /// 从 `GetWorkHours` 的返回数组里取「已填工时」的 JS 片段。
  ///
  /// 返回值是 `[总额度, 已填, 剩余]`，第 2 项才是已填；取不到时返回 null，
  /// 由调用方决定当成「未知」还是「0」——这两者含义完全不同。
  /// 供“查询工时”和“提交前防重复检查”共用的响应解析。
  ///
  /// BOSS 返回 `[总额度, 已填, 剩余]`，只能取第 2 项。提交脚本必须复用
  /// 同一份解析，避免两个入口对“今日是否已提交”作出不同判断。
  static const String pickUsedPreamble = '''
      function pickUsed(data) {
        if (!data || data.length < 2) return null;
        var used = parseFloat(data[1]);
        return isNaN(used) ? null : used;
      }
  ''';

  /// 生成抓取整月工时的脚本。
  ///
  /// [year] / [month] 指定月份；脚本会顺序请求该月每一天。
  /// 顺序而非并发：这是公司内部系统，逐条请求更温和，也便于中途失败时定位。
  ///
  /// 返回 JSON：`{"ok":true,"month":"2026-08","hours":{"2026-08-05":10.3,...}}`
  static String buildFetchMonthScript({
    required int year,
    required int month,
    required String captureStoreName,
  }) {
    final monthKey =
        '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}
        $pickUsedPreamble

        var YEAR = $year, MONTH = $month;
        var MONTH_KEY = ${jsonEncode(monthKey)};
        var SERVICE_URI = ${jsonEncode(hoursServiceUri)};

        var para = bossFindPara();
        if (!para) return ${BossSessionScript.noSessionResult};

        function pad(n) { return n < 10 ? '0' + n : '' + n; }

        var daysInMonth = new Date(YEAR, MONTH, 0).getDate();
        var hours = {};
        var failed = [];

        for (var day = 1; day <= daysInMonth; day++) {
          var dateStr = YEAR + '-' + pad(MONTH) + '-' + pad(day);

          var res = bossCall(para, SERVICE_URI, { SelectDate: dateStr });
          if (!res.ok) { failed.push(dateStr); continue; }

          var used = pickUsed(res.data);
          if (used === null) { failed.push(dateStr); continue; }
          // 只记有填报的天，0 不入表——月历页据此区分「未填」与「填了 0」
          if (used > 0) hours[dateStr] = used;
        }

        return JSON.stringify({
          ok: true,
          month: MONTH_KEY,
          days: daysInMonth,
          filled: Object.keys(hours).length,
          failed: failed,
          hours: hours
        });
      })();
    ''';
  }

  /// 生成查询单日已填工时的脚本，用于提交前检查当天是否已有日志。
  ///
  /// BOSS 允许同一天填多条，重复提交不会报错而是静默产生重复记录，
  /// 因此提交前必须先查一次。
  ///
  /// 返回 JSON：`{"ok":true,"used":10.3}`，`used > 0` 即当天已有日志。
  static String buildFetchSingleDayScript({
    required String dateStr,
    required String captureStoreName,
  }) {
    return '''
      (function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
        ${BossSessionScript.callPreamble()}
        $pickUsedPreamble

        var para = bossFindPara();
        if (!para) return JSON.stringify({ ok: false, reason: 'noSession' });

        var res = bossCall(
          para,
          ${jsonEncode(hoursServiceUri)},
          { SelectDate: ${jsonEncode(dateStr)} }
        );
        if (!res.ok) {
          return JSON.stringify({ ok: false, reason: res.reason });
        }

        var used = pickUsed(res.data);
        // 解不出数值时报失败而不是当成 0：
        // 「查不到」与「当天为零」在提交确认框里是两种完全不同的提示。
        if (used === null) return JSON.stringify({ ok: false, reason: 'parse' });
        return JSON.stringify({ ok: true, used: used });
      })();
    ''';
  }

  /// 解析单日查询结果，取不到时返回 null（表示未知，不等于 0）。
  static double? parseSingleDay(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['ok'] != true) return null;
      final used = decoded['used'];
      return used is num ? used.toDouble() : double.tryParse('$used');
    } catch (e) {
      return null;
    }
  }

  /// 解析脚本返回值为「日期 → 工时」表。
  static Map<String, double> parseResult(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['ok'] != true) return {};
      final hours = decoded['hours'];
      if (hours is! Map) return {};

      final result = <String, double>{};
      hours.forEach((key, value) {
        final parsed = value is num
            ? value.toDouble()
            : double.tryParse('$value');
        if (parsed != null) result['$key'] = parsed;
      });
      return result;
    } catch (e) {
      return {};
    }
  }
}
