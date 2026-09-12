import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  const BossLoginResult({required this.ok, this.message});

  final bool ok;
  final String? message;
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
/// 登录态来自共享 Cookie，与可见的日志系统页面是同一份；
/// 因此用户在网页上登录过一次之后，后台执行就能一直复用。
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
  static Future<BossSessionResult<T>> run<T>(
    Future<T?> Function(InAppWebViewController controller) action, {
    Duration timeout = sessionTimeout,
  }) async {
    HeadlessInAppWebView? headless;

    try {
      headless = _createHeadless();

      await headless.run();

      final controller = await _awaitSession(headless, timeout);
      if (controller == null) {
        return const BossSessionResult(BossSessionStatus.noSession);
      }

      final value = await action(controller);
      return BossSessionResult(BossSessionStatus.ok, value);
    } catch (e) {
      debugPrint('[BOSS 后台会话] 执行失败: $e');
      return const BossSessionResult(BossSessionStatus.failed);
    } finally {
      await headless?.dispose();
    }
  }

  /// 在隐藏 WebView 中调用 BOSS 网页自身的登录逻辑。
  ///
  /// 密码只作为本次方法参数进入 WebView 内存；不写 Cookie 以外的 App 存储，
  /// 不写日志，也不返回给调用方。成功后普通后台会话即可复用共享 Cookie。
  static Future<BossLoginResult> login({
    required String userName,
    required String password,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    HeadlessInAppWebView? headless;
    try {
      headless = _createHeadless();
      var deadline = DateTime.now().add(timeout);
      await headless.run().timeout(timeout);
      var started = false;
      var phase = 'pageLoading';
      while (DateTime.now().isBefore(deadline)) {
        final controller = headless.webViewController;
        if (controller != null) {
          try {
            // Cookie 可能已自动恢复，先探测同一账号的真实会话，再考虑填登录框。
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
                return const BossLoginResult(ok: true);
              }
              phase = '${decoded['phase'] ?? phase}';
              final error = _loginError(decoded['reason']);
              if (error != null) {
                return BossLoginResult(ok: false, message: error);
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
                return BossLoginResult(ok: false, message: start.message);
              }
              if (start.status == BossLoginStartStatus.started) {
                started = true;
                phase = 'authenticating';
                // 首页资源慢不应吃掉整个认证预算；登录动作始终只发起一次。
                deadline = DateTime.now().add(timeout);
              }
            }
          } on TimeoutException {
            break;
          } catch (_) {
            // 页面导航期间控制器可能暂不可用，继续等待；不输出包含密码的异常。
          }
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return BossLoginResult(
        ok: false,
        message: phase == 'businessSession'
            ? '账号已验证，但 BOSS 业务页面尚未就绪，请稍后重试'
            : started
            ? 'BOSS 账号认证超时，请检查网络后重试'
            : 'BOSS 登录页加载超时，请检查网络后重试',
      );
    } catch (_) {
      // 登录异常里可能夹带 evaluateJavascript 源码；源码含本次密码，绝不打印。
      debugPrint('[BOSS 后台登录] 执行失败（详细异常已省略）');
      return const BossLoginResult(ok: false, message: '后台登录失败，请稍后重试');
    } finally {
      await headless?.dispose();
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
  static Future<InAppWebViewController?> _awaitSession(
    HeadlessInAppWebView headless,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final controller = headless.webViewController;
      if (controller != null) {
        try {
          final probe = await controller.evaluateJavascript(
            source: BossSessionScript.buildReadyProbe(
              captureStoreName: WorkLogRequestCapture.storeName,
            ),
          );
          final decoded = jsonDecode(probe?.toString() ?? '{}');
          if (decoded is Map && decoded['ready'] == true) return controller;
        } catch (_) {
          // 页面还没起来，继续等
        }
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    return null;
  }
}
