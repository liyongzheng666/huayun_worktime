import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_edit_script.dart';

void main() {
  const objectId = 'WORKLOG_123';
  const rawData = <String, dynamic>{
    'EID': objectId,
    'ENAME': '原标题',
    'LOGCONTENT': '原内容',
    'ACTWORK': '8.0',
    'LOGDATE_DisplayValue': '2026-09-03',
    'PROJECTID': 'PROJECT_1',
    'PROJECTCODE': 'PROJECT_CODE_1',
    'PROJECTID_DisplayValue': '项目一',
    'AUDITOR': ';USERINFO_1',
    'COMPANY_CUSTOM_FIELD': '必须保留',
  };

  const record = BossWorkLogRecord(objectId: objectId, rawData: rawData);

  group('读取已提交日志', () {
    test('只接受目标 ID 与对象 EID 一致的完整记录', () {
      final parsed = WorkLogEditScript.parseFetchResult(
        jsonEncode({'ok': true, 'objectId': objectId, 'data': rawData}),
      );

      expect(parsed, isNotNull);
      expect(parsed!.title, '原标题');
      expect(parsed.content, '原内容');
      expect(parsed.hours, 8);
      expect(parsed.projectName, '项目一');
    });

    test('对象 EID 不一致时拒绝编辑，避免修改错记录', () {
      final parsed = WorkLogEditScript.parseFetchResult(
        jsonEncode({
          'ok': true,
          'objectId': objectId,
          'data': {...rawData, 'EID': 'WORKLOG_other'},
        }),
      );

      expect(parsed, isNull);
    });

    test('读取脚本只按 ObjectID 查询，不包含凭据', () {
      final script = WorkLogEditScript.buildFetch(
        objectId: objectId,
        captureStoreName: '__store',
      );

      expect(script.contains('GetObjectData'), isTrue);
      expect(script.contains(objectId), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('data.EID !== OBJECT_ID'), isTrue);
    });
  });

  group('识别在 BOSS 页面打开过的历史日志', () {
    test('只接受标准日期与 WORKLOG ID', () {
      final reference = WorkLogEditScript.parseDiscoveredReference(
        '{"ok":true,"date":"2026-09-03","objectId":"WORKLOG_123"}',
      );

      expect(reference?.date, '2026-09-03');
      expect(reference?.objectId, 'WORKLOG_123');
      expect(
        WorkLogEditScript.parseDiscoveredReference(
          '{"ok":true,"date":"2026/09/03","objectId":"PROJECT_123"}',
        ),
        isNull,
      );
    });

    test('发现脚本只读取 GetObjectData 响应中的 ID 与日期', () {
      final script = WorkLogEditScript.buildDiscoverCaptured(
        captureStoreName: '__store',
      );

      expect(script.contains('GetObjectData'), isTrue);
      expect(script.contains('LOGDATE_DisplayValue'), isTrue);
      expect(script.contains('WORKLOG_'), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('LOGCONTENT'), isFalse);
    });
  });

  group('构造更新对象', () {
    test('携带原记录三个 ID，确保更新而不是新建', () {
      final updated = WorkLogEditScript.buildUpdatedData(
        record: record,
        title: '新标题',
        content: '新内容',
        actWork: '9.50',
      );

      expect(updated['ObjectID'], objectId);
      expect(updated['EID'], objectId);
      expect(updated['SelectID'], objectId);
      expect(updated['ObjectType'], 'WORKLOG');
    });

    test('只覆盖可编辑字段，保留公司定制字段与项目审核人', () {
      final updated = WorkLogEditScript.buildUpdatedData(
        record: record,
        title: '新标题',
        content: '新内容',
        actWork: '9.50',
      );

      expect(updated['ENAME'], '新标题');
      expect(updated['LOGCONTENT'], '新内容');
      expect(updated['ACTWORK'], '9.50');
      expect(updated['PROJECTID'], 'PROJECT_1');
      expect(updated['AUDITOR'], ';USERINFO_1');
      expect(updated['COMPANY_CUSTOM_FIELD'], '必须保留');
      expect(rawData['ENAME'], '原标题', reason: '不得就地污染读取到的原对象');
    });
  });

  group('更新脚本', () {
    final updated = WorkLogEditScript.buildUpdatedData(
      record: record,
      title: '新标题',
      content: '新内容',
      actWork: '9.50',
    );
    final script = WorkLogEditScript.buildUpdate(
      workLogData: updated,
      captureStoreName: '__store',
    );

    test('更新前确认原对象存在，保存后重新读取同一 ID', () {
      final before = script.indexOf('var before = fetchCurrent()');
      final save = script.indexOf('SaveWorkLogObject');
      final after = script.indexOf('var after = fetchCurrent()');

      expect(before, greaterThanOrEqualTo(0));
      expect(save, greaterThan(before));
      expect(after, greaterThan(save));
      expect(script.contains('data.EID !== OBJECT_ID'), isTrue);
    });

    test('按标题、内容和时长复核，不只相信保存响应', () {
      expect(script.contains('matchesExpected'), isTrue);
      expect(script.contains('data.ENAME'), isTrue);
      expect(script.contains('data.LOGCONTENT'), isTrue);
      expect(script.contains('data.ACTWORK'), isTrue);
    });

    test('无法复核时按暂缓处理，避免立即重复更新', () {
      expect(script.contains('updateResultUnknown'), isTrue);
      expect(script.contains('deferred: true'), isTrue);
      expect(script.contains('请勿立即重试'), isTrue);
    });
  });

  group('更新结果分类', () {
    test('复读一致才算更新成功', () {
      final result = WorkLogEditScript.parseUpdateResult(
        '{"ok":true,"objectId":"WORKLOG_123","hours":9.5}',
      );
      expect(result.status, WorkLogUpdateStatus.updated);
      expect(result.hours, 9.5);
    });

    test('网络未知与确定失败分开', () {
      expect(
        WorkLogEditScript.parseUpdateResult(
          '{"ok":false,"deferred":true}',
        ).status,
        WorkLogUpdateStatus.deferred,
      );
      expect(
        WorkLogEditScript.parseUpdateResult(
          '{"ok":false,"failed":true}',
        ).status,
        WorkLogUpdateStatus.failed,
      );
    });
  });
}
