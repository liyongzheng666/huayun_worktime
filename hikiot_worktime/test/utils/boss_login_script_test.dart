import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_login_script.dart';

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
      final userBlur = script.indexOf("jQuery(user).trigger('blur')");
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
      expect(script.contains('TryLogin'), isFalse);
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
