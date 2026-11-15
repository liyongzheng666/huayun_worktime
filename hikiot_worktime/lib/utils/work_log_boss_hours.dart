import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
/// 在WebView内复用网页已认证的会话，业务请求的上下文与认证协议不搬到Dart。
/// 用户选择记住的登录密码由独立安全存储管理，不作为原生业务请求上下文使用。
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
        // 服务有时在 d 中继续包 JSON 字符串，不能把字符串的第二个字符当工时。
        for (var depth = 0; typeof data === 'string' && depth < 6; depth++) {
          try { data = JSON.parse(data); } catch (e) { return null; }
        }
        if (Object.prototype.toString.call(data) !== '[object Array]' ||
            data.length !== 3) return null;
        var raw = data[1];
        if (typeof raw !== 'number' && typeof raw !== 'string') return null;
        if (typeof raw === 'string' && raw.trim() === '') return null;
        var used = Number(raw);
        return isFinite(used) && used >= 0 ? used : null;
      }
  ''';

  /// 生成抓取整月工时的脚本。
  ///
  /// [year] / [month] 指定月份；最多3个只读请求并发，避免同步XHR阻塞网页。
  /// 返回Promise，原生调用必须使用 [fetchMonth] 等待异步桥接完成。
  ///
  /// 返回 JSON：`{"ok":true,"month":"2026-08","hours":{"2026-08-05":10.3,...}}`
  static String buildFetchMonthScript({
    required int year,
    required int month,
    required String captureStoreName,
    int requestTimeoutMs = 10000,
    int timeoutMs = 30000,
  }) {
    if (requestTimeoutMs <= 0 || timeoutMs <= 0) {
      throw ArgumentError('查询超时必须大于0');
    }
    final monthKey =
        '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

    return '''
      (async function() {
        ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
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
        var nextDay = 1;
        var deadline = Date.now() + $timeoutMs;
        var stopped = false;

        // 只在当前网页内克隆已验证的会话上下文，不回传或保存para。
        function readDay(dateStr) {
          return new Promise(function(resolve) {
            var remaining = deadline - Date.now();
            if (remaining <= 0) { resolve(null); return; }
            var outer = Object.assign({}, para, {ServiceUri:SERVICE_URI});
            var inner = Object.assign({}, para, {SelectDate:dateStr});
            delete inner.ServiceUri;
            var xhr = new XMLHttpRequest();
            xhr.open('POST', ${jsonEncode(BossSessionScript.dataServicePath)}, true);
            xhr.timeout = Math.min($requestTimeoutMs, remaining);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            xhr.onerror = xhr.ontimeout = xhr.onabort = function() { resolve(null); };
            xhr.onload = function() {
              if (xhr.status !== 200) { resolve(null); return; }
              try {
                var first = JSON.parse(xhr.responseText || '').d;
                var data = typeof first === 'string' ? JSON.parse(first).d : first;
                resolve(pickUsed(data));
              } catch (_) { resolve(null); }
            };
            try {
              xhr.send(JSON.stringify({para:outer,content:JSON.stringify({para:inner})}));
            } catch (_) { resolve(null); }
          });
        }

        async function worker() {
          while (!stopped && nextDay <= daysInMonth) {
            var day = nextDay++;
            var dateStr = YEAR + '-' + pad(MONTH) + '-' + pad(day);
            var used = await readDay(dateStr);
            if (used === null) { failed.push(dateStr); stopped=true; return; }
            // 只记正工时；仅全部日期成功时，缺席键才能代表已确认的0。
            if (used > 0) hours[dateStr] = used;
          }
        }
        await Promise.all([worker(),worker(),worker()]);
        failed.sort();

        return JSON.stringify({
          ok: failed.length === 0,
          month: MONTH_KEY,
          days: daysInMonth,
          filled: Object.keys(hours).length,
          failed: failed,
          hours: hours
        });
      })();
    ''';
  }

  /// Android evaluateJavascript不保证等待Promise；使用插件的异步桥并检查error。
  static Future<String?> fetchMonth({
    required InAppWebViewController controller,
    required int year,
    required int month,
    required String captureStoreName,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final script = buildFetchMonthScript(
      year: year,
      month: month,
      captureStoreName: captureStoreName,
    );
    final CallAsyncJavaScriptResult? result;
    try {
      result = await controller
          .callAsyncJavaScript(functionBody: 'return await $script')
          .timeout(timeout);
    } catch (_) {
      return null;
    }
    if (result == null || result.error != null || result.value is! String) {
      return null;
    }
    return result.value as String;
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
      final parsed = used is num ? used.toDouble() : double.tryParse('$used');
      return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
    } catch (e) {
      return null;
    }
  }

  /// 解析脚本返回值为「日期 → 工时」表。
  static Map<String, double> parseResult(String? raw) =>
      parseSuccessfulResult(raw) ?? {};

  /// 解析整月查询；失败返回 null，成功但没有日志返回空表。
  ///
  /// 自动刷新必须区分这两种状态，否则一次网络错误会用空表覆盖有效缓存。
  static Map<String, double>? parseSuccessfulResult(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['ok'] != true) return null;
      final failed = decoded['failed'];
      if (failed != null && (failed is! List || failed.isNotEmpty)) return null;
      final hours = decoded['hours'];
      if (hours is! Map) return null;

      final result = <String, double>{};
      for (final entry in hours.entries) {
        final key = entry.key;
        final value = entry.value;
        final parsed = value is num
            ? value.toDouble()
            : double.tryParse('$value');
        if (parsed == null || !parsed.isFinite || parsed < 0) return null;
        result['$key'] = parsed;
      }
      return result;
    } catch (_) {
      return null;
    }
  }
}
