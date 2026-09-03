import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../screens/work_report_webview_screen.dart';
import '../utils/boss_login_script.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/work_log_submit_script.dart';

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
      await headless.run();

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final controller = headless.webViewController;
        if (controller != null) {
          try {
            final raw = await controller.evaluateJavascript(
              source: BossLoginScript.build(
                userName: userName,
                password: password,
              ),
            );
            final start = BossLoginScript.parse(raw?.toString());
            if (start.status == BossLoginStartStatus.failed) {
              return BossLoginResult(ok: false, message: start.message);
            }
            if (start.status == BossLoginStartStatus.started) break;
          } catch (_) {
            // 登录页脚本仍在加载，继续等待。
          }
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        return const BossLoginResult(ok: false, message: '等待 BOSS 登录页超时');
      }
      final controller = await _awaitSession(headless, remaining);
      if (controller != null) return const BossLoginResult(ok: true);

      return const BossLoginResult(ok: false, message: '登录未成功，请核对账号、密码或网络状态');
    } catch (_) {
      // 登录异常里可能夹带 evaluateJavascript 源码；源码含本次密码，绝不打印。
      debugPrint('[BOSS 后台登录] 执行失败（详细异常已省略）');
      return const BossLoginResult(ok: false, message: '后台登录失败，请稍后重试');
    } finally {
      await headless?.dispose();
    }
  }

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

  /// 轮询等待页面发出带 `UserID` 的请求，返回可用的控制器。
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
            source: WorkLogSubmitScript.buildSessionProbeScript(
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
