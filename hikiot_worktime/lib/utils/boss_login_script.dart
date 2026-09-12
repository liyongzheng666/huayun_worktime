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
        function findLoginWindow(win) {
          try {
            if (win.document.getElementById('txtUserName') &&
                typeof win.InforCenter_Platform_Login_LoginCheck === 'function') {
              return win;
            }
            for (var i = 0; i < win.frames.length; i++) {
              var found = findLoginWindow(win.frames[i]);
              if (found) return found;
            }
          } catch (e) {}
          return null;
        }
        var target = findLoginWindow(window);
        if (!target) return JSON.stringify({ ok: false, reason: 'notReady' });
        return (function(window, document) {
        // 导航可能使 evaluateJavascript 的返回丢失；重试探测不能重复提交密码。
        if (window.__bossNativeLogin && window.__bossNativeLogin.requested) {
          return JSON.stringify({ ok: true, started: true });
        }
        var USER_NAME = ${jsonEncode(userName)};
        var PASSWORD = ${jsonEncode(password)};
        var user = document.getElementById('txtUserName');
        var password = document.getElementById('txtPassword');

        if (!user || !password ||
            typeof window.InforCenter_Platform_Login_LoginCheck !== 'function' ||
            !window.jQuery || !window.HoteamUI || !window.HoteamUI.CallAjax) {
          return JSON.stringify({ ok: false, reason: 'notReady' });
        }

        try {
          // WKWebView 隐藏页面不保证 focus/blur 的原生时序。只执行网页绑定的
          // blur 处理一次，避免移动焦点时再次 GetLoginUser 并清空刚填的密码。
          user.value = USER_NAME;
          user.dispatchEvent(new Event('input', { bubbles: true }));
          user.dispatchEvent(new Event('change', { bubbles: true }));
          window.jQuery(user).triggerHandler('blur');

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

          password.value = PASSWORD;
          password.dispatchEvent(new Event('input', { bubbles: true }));
          password.dispatchEvent(new Event('change', { bubbles: true }));

          // 不勾选网页的自动登录，避免创建保留 10 天的自动登录 Cookie。
          // 网页仍会写自己的 autoLoginInfo 会话 Cookie，App 不另存登录参数。
          var autoLogin = document.getElementById('autoLogin');
          if (autoLogin) {
            autoLogin.removeAttribute('checked');
            if (window.jQuery) window.jQuery(autoLogin).removeAttr('checked');
          }

          // 仅记录固定的阶段/错误码；不把网页异常、响应或会话参数带回 Dart。
          var state = window.__bossNativeLogin = { phase: 'authenticating' };
          function markFailure(name, reason) {
            var original = window[name];
            if (typeof original !== 'function') return;
            window[name] = function() {
              state.reason = reason;
              return original.apply(this, arguments);
            };
          }
          markFailure('InforCenter_Platform_Login_PasswordError', 'passwordRejected');
          markFailure('InforCenter_Platform_Login_LoginFailCountExceeded', 'accountLocked');
          markFailure('InforCenter_Platform_Login_MultiLogin', 'requiresWeb');
          var ajax = window.HoteamUI.CallAjax;
          var originalAsync = ajax.AsyncCall;
          ajax.AsyncCall = function(options) {
            if (options && options.method === 'TryLogin') {
              state.requested = true;
              var callback = options.callback;
              var errorCallback = options.errorCallback;
              options.callback = function(result) {
                if (!result || !result.LoginID) {
                  state.reason = state.reason || 'authenticationFailed';
                }
                var returned = callback.apply(this, arguments);
                var current = window.HoteamUI.Security.LoginPara;
                if (result && result.LoginID && current &&
                    current.LoginID === result.LoginID) state.phase = 'businessSession';
                return returned;
              };
              options.errorCallback = function() {
                state.reason = state.reason || 'authenticationFailed';
                if (errorCallback) return errorCallback.apply(this, arguments);
              };
            }
            return originalAsync.apply(this, arguments);
          };
          window.InforCenter_Platform_Login_LoginCheck();
          // 当前 BOSS LoginCheck 在返回前已同步读取并加密密码。
          PASSWORD = '';
          password.value = '';
          if (!state.requested) {
            state.reason = state.reason || 'requiresWeb';
          }
          return JSON.stringify({ ok: true, started: true });
        } catch (e) {
          PASSWORD = '';
          password.value = '';
          return JSON.stringify({
            ok: false,
            reason: 'pageError',
            message: 'BOSS 登录页处理失败，请重试或使用网页登录'
          });
        }
        })(target, target.document);
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
