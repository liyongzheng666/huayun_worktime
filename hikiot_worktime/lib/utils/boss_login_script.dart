import 'dart:convert';

/// 在 BOSS 自己的登录页内完成一次账号密码登录。
///
/// 不复刻服务端协议：用户名失焦后由网页自己的 `GetLoginUser` 解析用户、组织、
/// 语言和主题，密码也由网页自己的函数加密。App 只负责填两个输入框并调用页面
/// 已绑定的登录检查，因此不需要也不允许把加密密钥或会话参数搬到 Dart 层。
class BossLoginScript {
  BossLoginScript._();

  static String build({required String userName, required String password}) {
    return '''
      (function() {
        var USER_NAME = ${jsonEncode(userName)};
        var PASSWORD = ${jsonEncode(password)};
        var user = document.getElementById('txtUserName');
        var password = document.getElementById('txtPassword');

        if (!user || !password ||
            typeof window.InforCenter_Platform_Login_LoginCheck !== 'function') {
          return JSON.stringify({ ok: false, reason: 'notReady' });
        }

        try {
          // 触发页面原有的 blur 处理：它会同步调用 GetLoginUser，并自动绑定
          // UserID、组织、语言、主题等登录所需数据。直接只赋 value 会漏掉这些。
          user.focus();
          user.value = USER_NAME;
          user.dispatchEvent(new Event('input', { bubbles: true }));
          user.dispatchEvent(new Event('change', { bubbles: true }));
          if (window.jQuery) window.jQuery(user).trigger('blur');
          else user.blur();

          if (!window.LoginUserData) {
            return JSON.stringify({
              ok: false,
              reason: 'unknownUser',
              message: 'BOSS 未识别该用户名'
            });
          }

          var group = document.getElementById('ddlGroup');
          if (group && !group.value) {
            return JSON.stringify({
              ok: false,
              reason: 'groupRequired',
              message: '该账号需要手工选择登录组织'
            });
          }

          password.focus();
          password.value = PASSWORD;
          password.dispatchEvent(new Event('input', { bubbles: true }));
          password.dispatchEvent(new Event('change', { bubbles: true }));

          // 不勾选网页的自动登录；App 只复用登录成功后的 Cookie，不让网页把
          // 含加密密码的整份 LoginPara 额外写入 autoLoginInfo。
          var autoLogin = document.getElementById('autoLogin');
          if (autoLogin) {
            autoLogin.removeAttribute('checked');
            if (window.jQuery) window.jQuery(autoLogin).removeAttr('checked');
          }

          window.InforCenter_Platform_Login_LoginCheck();
          PASSWORD = '';
          password.value = '';
          return JSON.stringify({ ok: true, started: true });
        } catch (e) {
          PASSWORD = '';
          password.value = '';
          return JSON.stringify({
            ok: false,
            reason: 'pageError',
            message: String(e)
          });
        }
      })();
    ''';
  }

  static BossLoginStartResult parse(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map) return const BossLoginStartResult.notReady();
      if (decoded['ok'] == true && decoded['started'] == true) {
        return const BossLoginStartResult.started();
      }
      final reason = '${decoded['reason'] ?? ''}';
      if (reason == 'notReady') return const BossLoginStartResult.notReady();
      return BossLoginStartResult.failed(
        '${decoded['message'] ?? '网页登录初始化失败'}',
      );
    } catch (_) {
      return const BossLoginStartResult.notReady();
    }
  }
}

enum BossLoginStartStatus { started, notReady, failed }

class BossLoginStartResult {
  const BossLoginStartResult.started()
    : status = BossLoginStartStatus.started,
      message = null;

  const BossLoginStartResult.notReady()
    : status = BossLoginStartStatus.notReady,
      message = null;

  const BossLoginStartResult.failed(this.message)
    : status = BossLoginStartStatus.failed;

  final BossLoginStartStatus status;
  final String? message;
}
