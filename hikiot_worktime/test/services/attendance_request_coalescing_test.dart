import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('失败释放在途任务，重试仍可请求；不同日期和人员不合并', () async {
    var calls = 0;
    var fail = true;
    final api = HikiotApiClient(
      httpClient: MockClient((_) async {
        calls++;
        await Future<void>.delayed(Duration.zero);
        return http.Response(
          fail ? 'failed' : '{"code":0,"data":{}}',
          fail ? 500 : 200,
        );
      }),
    );
    await expectLater(
      api.getDailyAttendance('2026-11-15', 'person'),
      throwsException,
    );
    fail = false;
    await Future.wait([
      api.getDailyAttendance('2026-11-15', 'person'),
      api.getDailyAttendance('2026-11-16', 'person'),
      api.getDailyAttendance('2026-11-15', 'other'),
    ]);
    expect(calls, 4);
  });

  test('切换token或团队时拒绝旧在途结果，新身份独立请求', () async {
    final gates = <Completer<void>>[];
    final tokens = <String?>[];
    final api = HikiotApiClient(
      token: 'fixture-a',
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          final gate = Completer<void>();
          gates.add(gate);
          tokens.add(request.headers['token']);
          await gate.future;
        }
        return http.Response('{"code":0,"data":{}}', 200);
      }),
    );
    final old = api.getDailyAttendance('2026-11-15', 'person');
    final oldCheck = expectLater(old, throwsException);
    await Future<void>.delayed(Duration.zero);
    api.setToken('fixture-b');
    final next = api.getDailyAttendance('2026-11-15', 'person');
    await Future<void>.delayed(Duration.zero);
    gates[0].complete();
    gates[1].complete();
    await oldCheck;
    await next;
    expect(tokens, ['fixture-a', 'fixture-b']);
    final beforeTeam = api.getDailyAttendance('2026-11-15', 'person');
    final teamCheck = expectLater(beforeTeam, throwsException);
    await Future<void>.delayed(Duration.zero);
    await api.changeTeam('next-team');
    gates[2].complete();
    await teamCheck;
  });

  test('整月汇总与同日读取在真实客户端上共用一个HTTP响应', () async {
    final gate = Completer<void>();
    final requests = <String, int>{};
    final api = HikiotApiClient(
      httpClient: MockClient((request) async {
        final date = request.url.queryParameters['date']!;
        requests.update(date, (v) => v + 1, ifAbsent: () => 1);
        if (date == '2026-11-01') await gate.future;
        return http.Response('{"code":0,"data":{"dailyDetail":{}}}', 200);
      }),
    );
    final month = api.getMonthlyAttendance('2026-11', 'person');
    final day = api.getDailyAttendance('2026-11-01', 'person');
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([month, day]);
    expect(requests.length, 30);
    expect(requests.values.every((n) => n == 1), isTrue);
  });

  test('月度和单日调用同时读取同一天，只发一个请求，结果互不污染', () async {
    var calls = 0;
    final gate = Completer<void>();
    final api = HikiotApiClient(
      token: 'fixture-token',
      httpClient: MockClient((_) async {
        calls++;
        await gate.future;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'dailyDetail': {'hours': 8},
            },
          }),
          200,
        );
      }),
    );
    final a = api.getDailyAttendance('2026-11-15', 'person');
    final b = api.getDailyAttendance('2026-11-15', 'person');
    await Future<void>.delayed(Duration.zero);
    final observed = calls;
    gate.complete();
    final results = await Future.wait([a, b]);
    expect(observed, 1);
    (results[0]!['dailyDetail'] as Map)['hours'] = 99;
    expect((results[1]!['dailyDetail'] as Map)['hours'], 8);
    await api.getDailyAttendance('2026-11-15', 'person');
    expect(calls, 2, reason: '仅合并在途读取，显式再次读取仍取最新');
  });
}
