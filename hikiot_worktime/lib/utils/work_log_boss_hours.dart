import 'dart:convert';

/// BOSS 月度工时抓取
///
/// 用途：月历页除了展示海康打卡工时，还要展示 BOSS 系统里已填报的工时，
/// 便于一眼看出「打了卡但没填日志」或「填报工时和打卡对不上」。
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
        var YEAR = $year, MONTH = $month;
        var MONTH_KEY = ${jsonEncode(monthKey)};
        var SERVICE_URI = ${jsonEncode(hoursServiceUri)};

        // 复用页面刚发过的请求里的会话上下文，不在本地保存任何凭据
        function findPara() {
          var store = window.$captureStoreName || [];
          for (var i = store.length - 1; i >= 0; i--) {
            var e = store[i];
            if (!e || !e.body) continue;
            try {
              var p = JSON.parse(e.body);
              if (p && p.para && p.para.UserID && p.para.ServiceUri) return p.para;
            } catch (err) {}
          }
          return null;
        }

        var para = findPara();
        if (!para) {
          return JSON.stringify({
            ok: false,
            message: '未捕获到会话上下文，请先在页面上做一次操作（如切换日期）'
          });
        }

        function pad(n) { return n < 10 ? '0' + n : '' + n; }

        var daysInMonth = new Date(YEAR, MONTH, 0).getDate();
        var hours = {};
        var failed = [];

        for (var day = 1; day <= daysInMonth; day++) {
          var dateStr = YEAR + '-' + pad(MONTH) + '-' + pad(day);

          var outer = {};
          for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
          outer.ServiceUri = SERVICE_URI;

          var inner = {};
          for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
          delete inner.ServiceUri;
          inner.SelectDate = dateStr;

          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

          try {
            xhr.send(JSON.stringify({
              para: outer,
              content: JSON.stringify({ para: inner })
            }));
          } catch (err) {
            failed.push(dateStr);
            continue;
          }

          if (xhr.status !== 200) { failed.push(dateStr); continue; }

          // 响应形如 {"d":"{\\"d\\":[24,10.3,13.7]}"}，取数组第 2 项＝已填工时
          try {
            var lvl1 = JSON.parse(xhr.responseText).d;
            var lvl2 = typeof lvl1 === 'string' ? JSON.parse(lvl1).d : lvl1;
            if (lvl2 && lvl2.length >= 2) {
              var used = parseFloat(lvl2[1]);
              if (!isNaN(used) && used > 0) hours[dateStr] = used;
            }
          } catch (err) {
            failed.push(dateStr);
          }
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
        if (!para) return JSON.stringify({ ok: false, reason: 'noSession' });

        var outer = {};
        for (var k in para) { if (para.hasOwnProperty(k)) outer[k] = para[k]; }
        outer.ServiceUri = ${jsonEncode(hoursServiceUri)};

        var inner = {};
        for (var k2 in para) { if (para.hasOwnProperty(k2)) inner[k2] = para[k2]; }
        delete inner.ServiceUri;
        inner.SelectDate = ${jsonEncode(dateStr)};

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/Base/BaseService.asmx/DataService', false);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

        try {
          xhr.send(JSON.stringify({
            para: outer,
            content: JSON.stringify({ para: inner })
          }));
        } catch (e) {
          return JSON.stringify({ ok: false, reason: 'network' });
        }
        if (xhr.status !== 200) return JSON.stringify({ ok: false, reason: 'http' });

        try {
          var lvl1 = JSON.parse(xhr.responseText).d;
          var lvl2 = typeof lvl1 === 'string' ? JSON.parse(lvl1).d : lvl1;
          var used = (lvl2 && lvl2.length >= 2) ? parseFloat(lvl2[1]) : 0;
          return JSON.stringify({ ok: true, used: isNaN(used) ? 0 : used });
        } catch (e) {
          return JSON.stringify({ ok: false, reason: 'parse' });
        }
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
        final parsed = value is num ? value.toDouble() : double.tryParse('$value');
        if (parsed != null) result['$key'] = parsed;
      });
      return result;
    } catch (e) {
      return {};
    }
  }
}
