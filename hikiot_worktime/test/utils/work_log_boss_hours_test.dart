import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hikiot_worktime/utils/boss_session_script.dart';
import 'package:hikiot_worktime/utils/work_log_boss_hours.dart';

import '../support/javascript_runner.dart';

class _MonthBridge extends Fake implements InAppWebViewController {
  _MonthBridge(this.result, {this.neverCompletes = false});
  final CallAsyncJavaScriptResult? result;
  final bool neverCompletes;
  String? body;

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    body = functionBody;
    if (neverCompletes) return Completer<CallAsyncJavaScriptResult?>().future;
    return result;
  }
}

void main() {
  test('整月异步桥等待Promise并只接收value，错误和Promise占位对象均保留未知', () async {
    const raw = '{"ok":true,"failed":[],"hours":{"2026-10-01":10.2}}';
    for (final response in [
      CallAsyncJavaScriptResult(value: raw),
      CallAsyncJavaScriptResult(value: raw, error: 'query failed'),
      CallAsyncJavaScriptResult(value: <String, dynamic>{}),
      null,
    ]) {
      final controller = _MonthBridge(response);
      final result = await WorkLogBossHours.fetchMonth(
        controller: controller,
        year: 2026,
        month: 10,
        captureStoreName: '__store',
      );
      expect(
        result,
        response?.value == raw && response?.error == null ? raw : isNull,
      );
      expect(controller.body, startsWith('return await '));
    }
  });

  test('原生异步桥不回包时到预算即返回未知', () async {
    final result = await WorkLogBossHours.fetchMonth(
      controller: _MonthBridge(null, neverCompletes: true),
      year: 2026,
      month: 10,
      captureStoreName: '__store',
      timeout: const Duration(milliseconds: 5),
    );
    expect(result, isNull);
  });

  test('整月请求超时后停止派发，部分结果不能宣告成功', () {
    final script = WorkLogBossHours.buildFetchMonthScript(
      year: 2026,
      month: 10,
      captureStoreName: '__store',
      requestTimeoutMs: 2,
      timeoutMs: 1000,
    );
    final actual = runJavaScript('''
      var window={frames:[],__store:[{body:JSON.stringify({para:{UserID:'test',LoginID:'test'}})}]};
      var requests=0;
      class XMLHttpRequest {
        open(method,url,async) {if(!async) throw Error('must be async');}
        setRequestHeader() {}
        send() {requests++; setTimeout(()=>this.ontimeout(),this.timeout);}
      }
      var pending=$script
      Promise.resolve(pending).then(answer=>console.log(JSON.stringify({answer:JSON.parse(answer),requests})));
    ''');
    expect(actual['requests'], inInclusiveRange(1, 3));
    expect(actual['answer']['ok'], isFalse);
    expect(
      WorkLogBossHours.parseSuccessfulResult(jsonEncode(actual['answer'])),
      isNull,
    );
  });

  test('整月整体截止后不再派发日期，也不把未查询日期补成零', () {
    final script = WorkLogBossHours.buildFetchMonthScript(
      year: 2026,
      month: 10,
      captureStoreName: '__store',
      timeoutMs: 150,
    );
    final actual = runJavaScript('''
      var window={frames:[],__store:[{body:JSON.stringify({para:{UserID:'test',LoginID:'test'}})}]};
      var now=0,requests=0; Date.now=()=>now;
      class XMLHttpRequest {
        open() {} setRequestHeader() {}
        send() {
          requests++; now+=100; this.status=200;
          this.responseText=JSON.stringify({d:JSON.stringify({d:[24,10.2,13.8]})});
          this.onload();
        }
      }
      var pending=$script
      Promise.resolve(pending).then(answer=>console.log(JSON.stringify({answer:JSON.parse(answer),requests})));
    ''');
    expect(actual['requests'], 2);
    expect(actual['answer']['ok'], isFalse);
    expect(
      WorkLogBossHours.parseSuccessfulResult(jsonEncode(actual['answer'])),
      isNull,
    );
  });

  test('整月只读查询使用至多3个异步请求，让出网页事件循环', () {
    final script = WorkLogBossHours.buildFetchMonthScript(
      year: 2026,
      month: 10,
      captureStoreName: '__store',
    );
    final actual = runJavaScript('''
      var window = {frames:[],__store:[{body:JSON.stringify({para:{UserID:'test',LoginID:'test'}})}]};
      var requests=0, synchronous=0, active=0, peak=0, heartbeat=false;
      setTimeout(function(){heartbeat=true;},0);
      class XMLHttpRequest {
        open(method,url,async) {this.async=async;}
        setRequestHeader() {}
        send(raw) {
          requests++; active++; peak=Math.max(peak,active);
          var finish=()=>{
            active--; this.status=200;
            this.responseText=JSON.stringify({d:JSON.stringify({d:[24,10.2,13.8]})});
            if(this.onload) this.onload();
          };
          if(this.async) setTimeout(finish,2);
          else {synchronous++; finish();}
        }
      }
      var pending = $script
      Promise.resolve(pending).then(function(answer){
        console.log(JSON.stringify({answer:JSON.parse(answer),requests,synchronous,peak,heartbeat}));
      });
    ''');
    expect(actual['requests'], 31);
    expect(actual['synchronous'], 0);
    expect(actual['peak'], inInclusiveRange(2, 3));
    expect(actual['heartbeat'], isTrue);
    expect(actual['answer']['ok'], isTrue);
    expect(actual['answer']['hours'], hasLength(31));
  });

  group('真实工时响应解析回归', () {
    test('JSON字符串包装的三元组取第二项，不得按字符取成零', () {
      final values = [
        [0, 8.5, 0],
        jsonEncode([0, 8.5, 0]),
        jsonEncode(jsonEncode([0, 8.5, 0])),
      ];
      final actual = runJavaScript('''
        ${WorkLogBossHours.pickUsedPreamble}
        console.log(JSON.stringify(${jsonEncode(values)}.map(pickUsed)));
      ''');
      expect(actual, [8.5, 8.5, 8.5]);
    });

    test('错误形状和非完整数值均不能解析成已填零工时', () {
      final values = [
        '10',
        {'0': 8, '1': 0, 'length': 3},
        [8, '', 8],
        [8, '0错误', 8],
        [8, -1, 9],
        [8, 'Infinity', 0],
        [8, null, 8],
        [8, 0],
      ];
      final actual = runJavaScript('''
        ${WorkLogBossHours.pickUsedPreamble}
        console.log(JSON.stringify(${jsonEncode(values)}.map(pickUsed)));
      ''');
      expect(actual, List.filled(values.length, null));
    });

    test('整月任一天查询失败不能宣布整月成功', () {
      final script = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 9,
        captureStoreName: '__store',
      );
      final actual = runJavaScript('''
        var window = {frames:[],__store:[{body:JSON.stringify({para:{UserID:'test',LoginID:'test'}})}]};
        class XMLHttpRequest {
          open() {} setRequestHeader() {}
          send(raw) {
            var date=JSON.parse(JSON.parse(raw).content).para.SelectDate;
            this.status=date==='2026-09-10'?500:200;
            this.responseText=JSON.stringify({d:JSON.stringify({d:[8,8,0]})});
            if(this.onload) this.onload();
          }
        }
        var answer = $script
        Promise.resolve(answer).then(console.log);
      ''');
      expect(actual['ok'], isFalse);
      expect(actual['failed'], ['2026-09-10']);
      expect(
        WorkLogBossHours.parseSuccessfulResult(jsonEncode(actual)),
        isNull,
      );
    });

    test('旧脚本即使ok为真也必须拒绝带失败日期的部分结果', () {
      expect(
        WorkLogBossHours.parseSuccessfulResult(
          '{"ok":true,"failed":["2026-09-10"],"hours":{}}',
        ),
        isNull,
      );
      expect(
        WorkLogBossHours.parseSuccessfulResult(
          '{"ok":true,"failed":[],"hours":{"2026-09-10":"bad"}}',
        ),
        isNull,
      );
    });
  });
  group('parseSingleDay', () {
    test('取出已填工时', () {
      expect(WorkLogBossHours.parseSingleDay('{"ok":true,"used":10.3}'), 10.3);
    });

    test('未填报返回 0 而不是 null', () {
      expect(WorkLogBossHours.parseSingleDay('{"ok":true,"used":0}'), 0);
    });

    test('查询失败返回 null，表示「未知」而非「未填报」', () {
      // 这个区分很重要：未知时提交确认框应提示用户自行核对，
      // 而不是让用户误以为当天确定没有日志。
      expect(WorkLogBossHours.parseSingleDay('{"ok":false}'), isNull);
      expect(WorkLogBossHours.parseSingleDay('不是JSON'), isNull);
      expect(WorkLogBossHours.parseSingleDay(null), isNull);
      expect(WorkLogBossHours.parseSingleDay(''), isNull);
    });
  });

  group('parseResult', () {
    test('解析整月工时表', () {
      final hours = WorkLogBossHours.parseResult(
        '{"ok":true,"hours":{"2026-08-05":10.3,"2026-08-06":8}}',
      );
      expect(hours.length, 2);
      expect(hours['2026-08-05'], 10.3);
      expect(hours['2026-08-06'], 8.0);
    });

    test('失败或非法输入返回空表而不是抛异常', () {
      expect(WorkLogBossHours.parseResult('{"ok":false}'), isEmpty);
      expect(WorkLogBossHours.parseResult('坏数据'), isEmpty);
      expect(WorkLogBossHours.parseResult(null), isEmpty);
    });

    test('自动刷新解析能区分查询失败与成功的空月份', () {
      expect(
        WorkLogBossHours.parseSuccessfulResult('{"ok":true,"hours":{}}'),
        isEmpty,
      );
      expect(
        WorkLogBossHours.parseSuccessfulResult('{"ok":false,"hours":{}}'),
        isNull,
      );
      expect(WorkLogBossHours.parseSuccessfulResult('坏数据'), isNull);
    });
  });

  group('脚本约定', () {
    test('单日查询脚本不内嵌凭据，只复用抓包会话', () {
      final script = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      expect(script.contains('bossFindPara()'), isTrue);
      expect(script.contains('__store'), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('2026-08-05'), isTrue);
    });

    test('整月脚本与单日脚本共用同一套会话查找', () {
      // 历史教训：整月脚本曾经把 ServiceUri 也加进筛选条件，而单日脚本没有，
      // 表现为刚登录时同步整月报「未捕获到会话」、单日查询却正常，
      // 现象自相矛盾且极难排查（踩坑记录 3.11）。两者必须走同一份实现。
      final month = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 8,
        captureStoreName: '__store',
      );
      final single = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      final preamble = BossSessionScript.sessionPreamble(
        captureStoreName: '__store',
      );
      expect(month.contains(preamble), isTrue);
      expect(single.contains(preamble), isTrue);
    });

    test('单日与整月都用同一个「取已填工时」的解析，避免取错列', () {
      // 返回值是 [总额度, 已填, 剩余]，取错一位就会把额度当成已填
      final month = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 8,
        captureStoreName: '__store',
      );
      final single = WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: '__store',
      );

      expect(month.contains('function pickUsed(data)'), isTrue);
      expect(single.contains('function pickUsed(data)'), isTrue);
    });

    test('整月脚本按月份天数循环，不写死 31 天', () {
      final script = WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 2,
        captureStoreName: '__store',
      );
      expect(script.contains('new Date(YEAR, MONTH, 0).getDate()'), isTrue);
      expect(script.contains('var YEAR = 2026, MONTH = 2;'), isTrue);
    });
  });
}
