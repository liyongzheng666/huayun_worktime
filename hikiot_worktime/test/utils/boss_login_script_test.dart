import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_login_script.dart';

import '../support/javascript_runner.dart';

void main() {
  group('后台登录脚本', () {
    final script = BossLoginScript.build(
      userName: 'test-user',
      password: 'test-password',
    );

    test('使用真机页面确认过的输入框和网页自身登录函数', () {
      expect(script.contains("getElementById('txtUserName')"), isTrue);
      expect(script.contains("getElementById('txtPassword')"), isTrue);
      expect(script.contains('InforCenter_Platform_Login_LoginCheck'), isTrue);
    });

    test('先触发用户名失焦解析组织，再填写密码并登录', () {
      final userBlur = script.indexOf("jQuery(user).triggerHandler('blur')");
      final passwordFill = script.indexOf('password.value = PASSWORD');
      final login = script.indexOf(
        'window.InforCenter_Platform_Login_LoginCheck()',
      );

      expect(userBlur, greaterThanOrEqualTo(0));
      expect(passwordFill, greaterThan(userBlur));
      expect(login, greaterThan(passwordFill));
    });

    test('不复刻密码加密或 TryLogin 协议', () {
      expect(script.contains('EncryptDecrypt'), isFalse);
      expect(script.contains('new XMLHttpRequest'), isFalse);
      expect(script.contains("method: 'TryLogin'"), isFalse);
      expect(script.contains('LoginPara.UserID'), isFalse);
      expect(script.contains('UserID:'), isFalse);
    });

    test('登录动作发起后立即清空 JS 变量与密码输入框', () {
      expect(script.contains("PASSWORD = ''"), isTrue);
      expect(script.contains("password.value = ''"), isTrue);
    });

    test('主动关闭网页自动登录，避免网页额外持久化含密码的参数', () {
      expect(script.contains("getElementById('autoLogin')"), isTrue);
      expect(script.contains("removeAttribute('checked')"), isTrue);
    });
  });

  group('执行真实生成的登录脚本', () {
    Map<String, dynamic> execute({
      String completion = '',
      bool rejectStart = false,
      bool throwPageError = false,
      bool runTwice = false,
    }) {
      final script = BossLoginScript.build(
        userName: 'test-user',
        password: 'secret-value',
      );
      return runJavaScript('''
        let blurCount = 0, requests = 0, submittedPassword = null, pending;
        const user = { value: '', dispatchEvent() {},
          focus() { throw Error('hidden WKWebView must not depend on focus'); } };
        const password = { value: '', dispatchEvent() {},
          focus() { throw Error('hidden WKWebView must not depend on focus'); } };
        const group = { value: '测试组织' };
        const autoLogin = { removeAttribute() {} };
        const document = { getElementById(id) {
          return {txtUserName:user, txtPassword:password, ddlGroup:group, autoLogin}[id];
        }};
        const window = { document, frames: [], LoginUserData: null,
          HoteamUI: { Security: { LoginPara: {} }, CallAjax: { AsyncCall(options) { requests++; pending = options; } } },
          InforCenter_Platform_Login_PasswordError() {},
          InforCenter_Platform_Login_LoginFailCountExceeded() {},
          InforCenter_Platform_Login_MultiLogin() {},
          jQuery(element) { return {
            triggerHandler(name) {
              if (element === user && name === 'blur') {
                // 线上 Login.js 的用户名 blur 会清密码并同步 GetLoginUser。
                blurCount++; password.value = ''; window.LoginUserData = { UserID: 'test' };
              }
            }, removeAttr() {}
          }; },
          InforCenter_Platform_Login_LoginCheck() {
            if ($throwPageError) throw Error('secret-value should never escape');
            if ($rejectStart) return;
            // 线上 LoginCheck 先同步读取密码，Security.Login 再发起异步 TryLogin。
            submittedPassword = password.value;
            window.HoteamUI.CallAjax.AsyncCall({ method:'TryLogin',
              callback(result) {
                if (result) window.HoteamUI.Security.LoginPara.LoginID = result.LoginID;
              }, errorCallback() {} });
          }
        };
        const result = $script
        if ($runTwice) { $script }
        $completion
        console.log(JSON.stringify({result:JSON.parse(result), blurCount, requests,
          submittedPassword, remaining:password.value, state:window.__bossNativeLogin}));
      ''')
          as Map<String, dynamic>;
    }

    test('无需隐藏页面焦点，只解析一次用户名，并在网页消费后清空密码框', () {
      final value = execute();
      expect(value['result']['started'], isTrue);
      expect(value['blurCount'], 1);
      expect(value['requests'], 1);
      expect(value['submittedPassword'], 'secret-value');
      expect(value['remaining'], '');
      expect(value['state']['phase'], 'authenticating');
    });

    test('脚本返回丢失后再次调用也不会重复提交密码', () {
      final value = execute(runTwice: true);
      expect(value['requests'], 1);
      expect(value['blurCount'], 1);
    });

    test('TryLogin 真正回调成功后才进入业务会话阶段', () {
      final value = execute(
        completion: "pending.callback({LoginID:'current'});",
      );
      expect(value['state']['phase'], 'businessSession');
      expect(jsonEncode(value['state']), isNot(contains('current')));
    });

    test('网页密码拒绝和账号锁定返回固定原因而非一直等待', () {
      for (final failure in {
        'PasswordError': 'passwordRejected',
        'LoginFailCountExceeded': 'accountLocked',
        'MultiLogin': 'requiresWeb',
      }.entries) {
        final value = execute(
          completion:
              'window.InforCenter_Platform_Login_${failure.key}(); pending.errorCallback();',
        );
        expect(value['state']['reason'], failure.value);
        expect(value['state']['phase'], 'authenticating');
      }
    });

    test('空认证响应和表单校验中断不会误报已认证', () {
      expect(
        execute(completion: 'pending.callback(null);')['state']['reason'],
        'authenticationFailed',
      );
      expect(execute(rejectStart: true)['state']['reason'], 'requiresWeb');
    });

    test('页面异常不会把包含密码的异常文本返回 Dart', () {
      final value = execute(throwPageError: true);
      expect(value['result']['ok'], isFalse);
      expect(jsonEncode(value['result']), isNot(contains('secret-value')));
      expect(value['remaining'], '');
    });
  });

  group('启动结果解析', () {
    test('区分已发起、页面未就绪和确定失败', () {
      expect(
        BossLoginScript.parse('{"ok":true,"started":true}').status,
        BossLoginStartStatus.started,
      );
      expect(
        BossLoginScript.parse('{"ok":false,"reason":"notReady"}').status,
        BossLoginStartStatus.notReady,
      );
      expect(
        BossLoginScript.parse(
          '{"ok":false,"reason":"unknownUser","message":"用户名错误"}',
        ).status,
        BossLoginStartStatus.failed,
      );
    });

    test('脏返回按页面未就绪处理，不抛异常', () {
      expect(
        BossLoginScript.parse('坏数据').status,
        BossLoginStartStatus.notReady,
      );
    });
  });
}
