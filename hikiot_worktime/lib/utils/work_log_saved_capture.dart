import 'dart:convert';

import 'boss_session_script.dart';
import 'work_log_edit_script.dart';
import 'work_log_submit_script.dart';

/// 只消费网页已确认保存的业务索引，不导出请求正文或会话信息。
class WorkLogSavedCapture {
  WorkLogSavedCapture._();

  static String build({required String captureStoreName}) =>
      '''
    (function() {
      ${BossSessionScript.sessionPreamble(captureStoreName: captureStoreName)}
      function unwrap(value) {
        for (var depth = 0; depth < 6; depth++) {
          if (typeof value === 'string') {
            try { value = JSON.parse(value); } catch (e) { return value; }
          } else if (value && value.d !== undefined) {
            value = value.d;
          } else {
            return value;
          }
        }
        return value;
      }
      function dateKey(value) {
        var text = String(value || '');
        var match = /^(\\d{4})-?(\\d{2})-?(\\d{2})\$/.exec(text) ||
          /^(\\d{4})-(\\d{1,2})-(\\d{1,2})\$/.exec(text);
        if (!match) return null;
        var y = Number(match[1]), m = Number(match[2]), d = Number(match[3]);
        var date = new Date(Date.UTC(y, m - 1, d));
        if (date.getUTCFullYear() !== y || date.getUTCMonth() !== m - 1 ||
            date.getUTCDate() !== d) return null;
        return match[1] + '-' + ('0' + m).slice(-2) + '-' + ('0' + d).slice(-2);
      }
      var events = [], store = bossCaptured();
      for (var i = 0; i < store.length; i++) {
        var entry = store[i];
        // 记录在 loadend 时加入；标记已观察项，后续轮询不重解析旧报文。
        if (!entry || entry.__workLogObservedSave) continue;
        entry.__workLogObservedSave = true;
        if (entry.status !== 200 || !entry.body || !entry.response) continue;
        try {
          var request = JSON.parse(entry.body);
          if (!request.para || request.para.ServiceUri !==
              ${jsonEncode(WorkLogSubmitScript.saveServiceUri)}) continue;
          var objectId = unwrap(entry.response);
          if (typeof objectId !== 'string' || objectId.indexOf('WORKLOG_') !== 0) continue;
          var content = typeof request.content === 'string'
            ? JSON.parse(request.content) : request.content;
          var data = content && content.para && content.para.workLogData;
          if (typeof data === 'string') data = JSON.parse(data);
          if (!data || typeof data !== 'object') continue;
          if ((data.EID && data.EID !== objectId) ||
              (data.ObjectID && data.ObjectID !== objectId) ||
              (data.SelectID && data.SelectID !== objectId)) continue;
          var date = null, invalid = false;
          var fields = [data.LOGDATE, data.SelectDate, data.LOGDATE_DisplayValue];
          for (var j = 0; j < fields.length; j++) {
            if (fields[j] === undefined || fields[j] === null || fields[j] === '') continue;
            var normalized = dateKey(fields[j]);
            if (!normalized || (date && normalized !== date)) { invalid = true; break; }
            date = normalized;
          }
          if (!invalid && date) events.push({date: date, objectId: objectId});
        } catch (e) {}
      }
      return JSON.stringify(events);
    })();
  ''';

  static List<BossWorkLogReference> parse(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '[]');
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (value) => WorkLogEditScript.parseDiscoveredReference(
              jsonEncode({'ok': true, ...value}),
            ),
          )
          .whereType<BossWorkLogReference>()
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
