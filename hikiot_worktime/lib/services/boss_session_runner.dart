import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'boss_credentials_service.dart';

import '../screens/work_report_webview_screen.dart';
import '../utils/boss_login_script.dart';
import '../utils/boss_session_script.dart';
import '../utils/work_log_request_capture.dart';

/// 无头 BOSS 会话执行结果
enum BossSessionStatus {
  /// 操作已执行（成功与否由返回值表达）
  ok,

  /// 网页会话不可用：多半是没登录或登录态过期，需要用户打开网页登录
  noSession,

  /// 网页加载或脚本执行本身出错
  failed,
}

class BossSessionResult<T> {
  const BossSessionResult(this.status, [this.value]);

  final BossSessionStatus status;
  final T? value;

  bool get isOk => status == BossSessionStatus.ok;
}

class BossLoginResult {
  const BossLoginResult({
    required this.ok,
    this.message,
    this.reason,
    this.passwordAuthenticated = false,
  });

  final bool ok;
  final String? message;
  final String? reason;
  final bool passwordAuthenticated;
}

/// 在**不显示网页**的前提下执行 BOSS 网页会话内的操作
///
/// 为什么必须借助 WebView：BOSS 把凭据放在每个业务请求体里，
/// 我们刻意不把会话上下文存进 APP（见 docs/踩坑记录.md 3.12），
/// 只能就地复用页面自己发出的 `para`。
///
/// 但**「必须在网页会话里跑」不等于「必须让用户看见网页」**。
/// 同步工时、提交日志这类操作跳转到网页再跳回来，是把实现细节
/// 漏到了界面上。这里用 `HeadlessInAppWebView` 在后台加载首页、
/// 等页面自己发出带 `para` 的请求，然后执行操作，全程无跳转。
///
/// 优先复用与可见页面共享的Cookie；过期后可用当前已验证身份的安全凭据恢复。
/// 密码拒绝或需要额外认证时停止自动尝试，交回人工流程。
class BossSessionRunner {
  BossSessionRunner._();

  /// 等待会话就绪的上限。
  ///
  /// 首页要加载并发出若干带 para 的请求才算就绪，给足时间；
  /// 但也不能无限等——没登录时再等也不会有结果，应尽早退回让用户去登录。
  static const Duration sessionTimeout = Duration(seconds: 20);

  /// 在后台网页会话中执行 [action]。
  ///
  /// 会话不可用时返回 [BossSessionStatus.noSession]，由调用方决定
  /// 是提示用户去登录，还是打开可见的网页页面。
  static final Map<String, Future<BossLoginResult>> _authentication = {};

  static Future<BossSessionResult<T>> run<T>(
    Future<T?> Function(InAppWebViewController controller) action, {
    Duration timeout = sessionTimeout,
    BossCredentialsService? credentialsService,
    String? expectedScope,
  }) async {
    final credentials = credentialsService ?? BossCredentialsService();
    HeadlessInAppWebView? headless;
    try {
      final scope = await credentials.currentScope();
      if (scope == null || (expectedScope != null && scope != expectedScope)) {
        return const BossSessionResult(BossSessionStatus.noSession);
      }
      final saved = await credentials.loadForCurrentScope();
      final bound = await credentials.isCurrentSessionBound();
      // 未经用户确认的主账号不得复用上一账号留下的网页Cookie。
      if (!bound && saved == null) {
        return const BossSessionResult(BossSessionStatus.noSession);
      }
      headless = _createHeadless();
      await headless.run();
      var probe = await _awaitSession(
        headless,
        timeout,
        expectedUserName: saved?.userName,
      );
      if (probe.needsLogin && saved != null) {
        final restored = await _restoreInView(
          headless,
          saved,
          credentials,
          timeout,
        );
        if (!restored.ok) {
          return const BossSessionResult(BossSessionStatus.noSession);
        }
        probe = await _awaitSession(
          headless,
          timeout,
          expectedUserName: saved.userName,
        );
      }
      final controller = probe.controller;
      if (controller == null || await credentials.currentScope() != scope) {
        return const BossSessionResult(BossSessionStatus.noSession);
      }
      await credentials.bindCurrentSession(expectedScope: scope);
      // action只执行一次；超时或未知写入结果不能触发再次认证后重放保存。
      final value = await action(controller);
      if (await credentials.currentScope() != scope) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      return BossSessionResult(BossSessionStatus.ok, value);
    } catch (_) {
      debugPrint('[BOSS 后台会话] 执行失败（详细异常已省略）');
      return const BossSessionResult(BossSessionStatus.failed);
    } finally {
      await headless?.dispose();
    }
  }

  static Future<BossLoginResult> _restoreInView(
    HeadlessInAppWebView headless,
    BossSavedCredentials saved,
    BossCredentialsService credentials,
    Duration timeout,
  ) async {
    final running = _authentication[saved.scope];
    if (running != null) {
      final result = await running;
      if (result.ok && await credentials.currentScope() == saved.scope) {
        // 其它隐藏视图需要重新载入，才能消费刚更新的共享Cookie。
        await headless.webViewController?.reload();
      }
      return result;
    }
    if (!credentials.claimAutomaticAttempt(saved)) {
      return const BossLoginResult(ok: false, reason: 'automaticLoginPaused');
    }
    final future = _loginInView(
      headless,
      userName: saved.userName,
      password: saved.password,
      timeout: timeout,
    );
    _authentication[saved.scope] = future;
    try {
      final result = await future;
      if (await credentials.currentScope() != saved.scope) {
        return const BossLoginResult(ok: false, reason: 'identityChanged');
      }
      if (result.ok) {
        await credentials.bindCurrentSession(expectedScope: saved.scope);
      } else if (_loginError(result.reason) != null) {
        final current = await credentials.loadForCurrentScope();
        if (current?.userName == saved.userName &&
            current?.password == saved.password) {
          await credentials.disableAutomaticLogin(saved.scope);
        }
      }
      return result;
    } finally {
      if (identical(_authentication[saved.scope], future)) {
        _authentication.remove(saved.scope);
      }
    }
  }

  /// 记住密码后的只读恢复入口，不执行任何业务保存。
  static Future<bool> restoreRememberedSession({
    BossCredentialsService? credentialsService,
  }) async {
    final result = await run<bool>(
      (_) async => true,
      credentialsService: credentialsService,
    );
    return result.isOk && result.value == true;
  }

  /// 手工网页登录完成后，显式绑定当前主账号；不保存或推断密码。
  static Future<bool> bindWebSession({
    BossCredentialsService? credentialsService,
    String? expectedScope,
  }) async {
    final credentials = credentialsService ?? BossCredentialsService();
    HeadlessInAppWebView? headless;
    try {
      final scope = await credentials.currentScope();
      if (scope == null || (expectedScope != null && scope != expectedScope)) {
        return false;
      }
      final saved = await credentials.loadForCurrentScope();
      headless = _createHeadless();
      await headless.run();
      final probe = await _awaitSession(
        headless,
        sessionTimeout,
        expectedUserName: saved?.userName,
      );
      if (probe.controller == null ||
          await credentials.currentScope() != scope) {
        return false;
      }
      await credentials.bindCurrentSession(expectedScope: scope);
      return true;
    } catch (_) {
      return false;
    } finally {
      await headless?.dispose();
    }
  }

  /// 认证成功须等网页真实业务会话就绪；Cookie复用不等于验证了本次新密码。
  static Future<BossLoginResult> login({
    required String userName,
    required String password,
    Duration timeout = const Duration(seconds: 30),
    BossCredentialsService? credentialsService,
    String? expectedScope,
  }) async {
    final credentials = credentialsService ?? BossCredentialsService();
    HeadlessInAppWebView? headless;
    try {
      final scope = await credentials.currentScope();
      if (scope == null || (expectedScope != null && scope != expectedScope)) {
        return const BossLoginResult(
          ok: false,
          reason: 'identityNotReady',
          message: '主账号身份尚未确认，请稍后重试',
        );
      }
      headless = _createHeadless();
      await headless.run().timeout(timeout);
      final result = await _loginInView(
        headless,
        userName: userName,
        password: password,
        timeout: timeout,
      );
      if (await credentials.currentScope() != scope) {
        return const BossLoginResult(
          ok: false,
          reason: 'identityChanged',
          message: '主账号已变化，请重新确认登录',
        );
      }
      if (result.ok) await credentials.bindCurrentSession(expectedScope: scope);
      return result;
    } catch (_) {
      debugPrint('[BOSS 后台登录] 执行失败（详细异常已省略）');
      return const BossLoginResult(ok: false, message: '后台登录失败，请稍后重试');
    } finally {
      await headless?.dispose();
    }
  }

  static Future<BossLoginResult> _loginInView(
    HeadlessInAppWebView headless, {
    required String userName,
    required String password,
    required Duration timeout,
  }) async {
    try {
      var deadline = DateTime.now().add(timeout);
      var started = false;
      var phase = 'pageLoading';
      while (DateTime.now().isBefore(deadline)) {
        final controller = headless.webViewController;
        if (controller != null) {
          try {
            final probe = await controller
                .evaluateJavascript(
                  source: BossSessionScript.buildReadyProbe(
                    captureStoreName: WorkLogRequestCapture.storeName,
                    expectedUserName: userName.trim(),
                  ),
                )
                .timeout(deadline.difference(DateTime.now()));
            final decoded = jsonDecode(probe?.toString() ?? '{}');
            if (decoded is Map) {
              if (decoded['ready'] == true) {
                return BossLoginResult(
                  ok: true,
                  passwordAuthenticated:
                      started && decoded['phase'] == 'businessSession',
                );
              }
              phase = '${decoded['phase'] ?? phase}';
              final reason = decoded['reason']?.toString();
              final error = _loginError(reason);
              if (error != null) {
                return BossLoginResult(
                  ok: false,
                  message: error,
                  reason: reason,
                );
              }
            }
            if (!started && DateTime.now().isBefore(deadline)) {
              final raw = await controller
                  .evaluateJavascript(
                    source: BossLoginScript.build(
                      userName: userName,
                      password: password,
                    ),
                  )
                  .timeout(deadline.difference(DateTime.now()));
              final start = BossLoginScript.parse(raw?.toString());
              if (start.status == BossLoginStartStatus.failed) {
                final data = jsonDecode(raw?.toString() ?? '{}');
                final reason = data is Map ? data['reason']?.toString() : null;
                return BossLoginResult(
                  ok: false,
                  message: _loginError(reason) ?? start.message,
                  reason: _loginError(reason) == null ? 'pageError' : reason,
                );
              }
              if (start.status == BossLoginStartStatus.started) {
                started = true;
                phase = 'authenticating';
                deadline = DateTime.now().add(timeout);
              }
            }
          } on TimeoutException {
            break;
          } catch (_) {
            /* 导航时可暂不可用，不打印含密码的源码异常。 */
          }
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return BossLoginResult(
        ok: false,
        reason: 'timeout',
        message: phase == 'businessSession'
            ? '账号已验证，但 BOSS 业务页面尚未就绪，请稍后重试'
            : started
            ? 'BOSS 账号认证超时，请检查网络后重试'
            : 'BOSS 登录页加载超时，请检查网络后重试',
      );
    } catch (_) {
      return const BossLoginResult(
        ok: false,
        reason: 'pageError',
        message: '后台登录失败，请稍后重试',
      );
    }
  }

  // 网页只回传固定错误码，避免显示包含请求参数的服务端异常。
  static String? _loginError(Object? reason) => switch (reason) {
    'passwordRejected' => 'BOSS 密码不正确，请核对后重试',
    'accountLocked' => 'BOSS 登录错误次数过多，请稍后重试或联系管理员',
    'requiresWeb' => 'BOSS 需要额外确认，请使用“网页登录”完成',
    'differentUser' => 'BOSS 当前登录了其他账号，请使用“网页登录”切换账号',
    'authenticationFailed' => 'BOSS 未完成认证，请核对账号密码或稍后重试',
    _ => null,
  };

  static HeadlessInAppWebView _createHeadless() {
    return HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(WorkReportEntry.host)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        cacheEnabled: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
          source: WorkLogRequestCapture.buildHookScript(),
        ),
      ]),
    );
  }

  /// 轮询等待认证完成且页面发出当前会话的业务请求，返回可用的控制器。
  ///
  /// 不能只等 `onLoadStop`：页面加载完之后才会陆续发业务请求，
  /// 而我们要的 `para` 正是从那些请求里来的。
  static Future<_BossSessionProbe> _awaitSession(
    HeadlessInAppWebView headless,
    Duration timeout, {
    String? expectedUserName,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final controller = headless.webViewController;
      if (controller != null) {
        try {
          final probe = await controller.evaluateJavascript(
            source: BossSessionScript.buildReadyProbe(
              captureStoreName: WorkLogRequestCapture.storeName,
              expectedUserName: expectedUserName,
            ),
          );
          final decoded = jsonDecode(probe?.toString() ?? '{}');
          if (decoded is Map) {
            if (decoded['ready'] == true) {
              return _BossSessionProbe(controller: controller);
            }
            if (decoded['reason'] != null) return const _BossSessionProbe();
            if (decoded['needsLogin'] == true &&
                decoded['phase'] != 'authenticating' &&
                decoded['phase'] != 'businessSession') {
              return const _BossSessionProbe(needsLogin: true);
            }
          }
        } catch (_) {
          /* 页面加载期间继续等待。 */
        }
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return const _BossSessionProbe();
  }
}

class _BossSessionProbe {
  const _BossSessionProbe({this.controller, this.needsLogin = false});
  final InAppWebViewController? controller;
  final bool needsLogin;
}
