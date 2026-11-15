import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_saved_capture.dart';
import 'package:hikiot_worktime/utils/work_log_submit_script.dart';

// 执行真正生成的 JS，防止只检查字符串而漏掉运行时类型错误。
Future<dynamic> evaluate(String source) async {
  final result = await Process.run('node', ['-e', source]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return jsonDecode('${result.stdout}');
}

Map<String, dynamic> saveEvent({
  String date = '20260909',
  String? selectDate,
  String objectId = 'WORKLOG_web',
  String? editId,
  int status = 200,
  Object? reply,
}) => {
  'at': '2026-09-16T12:00:00.000Z',
  'status': status,
  'body': jsonEncode({
    'para': {
      'ServiceUri': WorkLogSubmitScript.saveServiceUri,
      'Password': 'test-secret',
    },
    'content': jsonEncode({
      'para': {
        'workLogData': jsonEncode({
          'LOGDATE': date,
          'SelectDate': ?selectDate,
          'EID': ?editId,
          'ACTWORK': '8.00',
        }),
      },
    }),
  }),
  'response': jsonEncode({
    'd': jsonEncode({'d': reply ?? objectId}),
  }),
};

void main() {
  final capture = WorkLogSavedCapture.build(captureStoreName: '__store');

  test('实际执行识别同源iframe内的新建/编辑成功，只返回日期与记录ID', () async {
    final window = {
      '__store': <dynamic>[],
      'frames': [
        {
          '__store': [
            saveEvent(selectDate: '2026-9-9'),
            saveEvent(date: '20260910', editId: 'WORKLOG_web'),
          ],
          'frames': <dynamic>[],
        },
      ],
    };
    final result = await evaluate('''
      const window = ${jsonEncode(window)};
      console.log(eval(${jsonEncode(capture)}));
    ''');
    expect(result, [
      {'date': '2026-09-09', 'objectId': 'WORKLOG_web'},
      {'date': '2026-09-10', 'objectId': 'WORKLOG_web'},
    ]);
    expect('$result', isNot(contains('test-secret')));
  });

  test('失败、未知响应、无效/冲突日期和错误编辑ID均不能确认保存', () async {
    final entries = [
      saveEvent(status: 500),
      saveEvent(reply: {'ok': true}),
      saveEvent(reply: false),
      saveEvent(date: '20260230'),
      saveEvent(date: '20260909', selectDate: '2026-9-10'),
      saveEvent(editId: 'WORKLOG_other'),
    ];
    final result = await evaluate('''
      const window = {__store: ${jsonEncode(entries)}, frames: []};
      const result = eval(${jsonEncode(capture)});
      console.log(result);
    ''');
    expect(result, isEmpty);
  });

  test('增量消费同一事件一次，同一ID后续再次编辑仍会产生新事件', () async {
    final result = await evaluate('''
      const window = {__store: [${jsonEncode(saveEvent())}], frames: []};
      const first = JSON.parse(eval(${jsonEncode(capture)}));
      const second = JSON.parse(eval(${jsonEncode(capture)}));
      window.__store.push(${jsonEncode(saveEvent(date: '20260910', editId: 'WORKLOG_web'))});
      const third = JSON.parse(eval(${jsonEncode(capture)}));
      console.log(JSON.stringify([first, second, third]));
    ''');
    expect((result as List)[0], hasLength(1));
    expect(result[1], isEmpty);
    expect(result[2], [
      {'date': '2026-09-10', 'objectId': 'WORKLOG_web'},
    ]);
  });

  test('新建成功返回记录ID，不将输入时长或null字段当作日合计', () async {
    final script = WorkLogSubmitScript.build(
      workLogData: {'ACTWORK': '8.00'},
      dateStr: '2026-09-10',
      captureStoreName: '__store',
    );
    final result = await evaluate('''
      const window = {__store: [{body: JSON.stringify({para: {UserID: 'test'}})}], frames: []};
      let saves = 0;
      class XMLHttpRequest {
        open() {}
        setRequestHeader() {}
        send(body) {
          const service = JSON.parse(body).para.ServiceUri;
          const isSave = service === ${jsonEncode(WorkLogSubmitScript.saveServiceUri)};
          if (isSave) saves++;
          this.status = 200;
          this.responseText = JSON.stringify({d: JSON.stringify({d: isSave ? 'WORKLOG_saved' : [8, 0, 8]})});
        }
      }
      const result = JSON.parse(eval(${jsonEncode(script)}));
      console.log(JSON.stringify({result, saves}));
    ''');
    expect(result['result'], {'ok': true, 'objectId': 'WORKLOG_saved'});
    expect(result['saves'], 1);
  });
}
