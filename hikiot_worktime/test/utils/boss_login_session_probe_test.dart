import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_session_script.dart';

import '../support/javascript_runner.dart';

void main() {
  Map<String, dynamic> probe({
    required Map<String, dynamic> pageSession,
    required List<Map<String, dynamic>> requests,
    bool loginFormVisible = false,
  }) {
    final script = BossSessionScript.buildReadyProbe(
      captureStoreName: '__capture',
    );
    return runJavaScript('''
      const document = { getElementById: () => $loginFormVisible ? {} : null };
      const window = {
        frames: [],
        HoteamUI: { Security: { LoginPara: ${jsonEncode(pageSession)} } },
        __capture: ${jsonEncode(requests.map((para) => {
          'body': jsonEncode({'para': para}),
        }).toList())}
      };
      const result = $script
      console.log(result);
    ''')
        as Map<String, dynamic>;
  }

  test('用户名已解析、TryLogin 仍在等待时不得判为登录成功', () {
    expect(
      probe(
        pageSession: {'UserID': 'USERINFO_test'},
        requests: [
          {'UserID': 'USERINFO_test', 'UserName': '测试用户'},
        ],
      )['ready'],
      isFalse,
    );
  });

  test('密码被拒绝后留下的 UserID 抓包不得判为登录成功', () {
    expect(
      probe(
        pageSession: {'UserID': 'USERINFO_test', 'LoginID': ''},
        requests: [
          {'UserID': 'USERINFO_test', 'Password': 'invalid-encrypted-value'},
        ],
      )['ready'],
      isFalse,
    );
  });

  test('认证回调完成但抓包仍属认证前或旧会话时继续等业务请求', () {
    expect(
      probe(
        pageSession: {'UserID': 'USERINFO_test', 'LoginID': 'current-session'},
        requests: [
          {'UserID': 'USERINFO_test'},
          {'UserID': 'USERINFO_test', 'LoginID': 'old-session'},
        ],
      )['ready'],
      isFalse,
    );
  });

  test('认证完成且首页发出当前会话请求后才就绪，不返回凭据', () {
    final result = probe(
      pageSession: {'UserID': 'USERINFO_test', 'LoginID': 'current-session'},
      requests: [
        {
          'UserID': 'USERINFO_test',
          'LoginID': 'current-session',
          'Password': 'encrypted-secret',
        },
      ],
    );
    expect(result['ready'], isTrue);
    expect(jsonEncode(result), isNot(contains('current-session')));
    expect(jsonEncode(result), isNot(contains('encrypted-secret')));
  });

  test('失效 Cookie 已写入 LoginPara 但页面仍要求登录时不可用', () {
    expect(
      probe(
        pageSession: {'UserID': 'USERINFO_test', 'LoginID': 'expired-session'},
        requests: [
          {'UserID': 'USERINFO_test', 'LoginID': 'expired-session'},
        ],
        loginFormVisible: true,
      )['ready'],
      isFalse,
    );
  });
}
