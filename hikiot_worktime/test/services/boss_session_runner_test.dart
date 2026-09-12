import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/utils/work_log_request_capture.dart';

import '../support/javascript_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SessionPlatform platform;

  setUp(() {
    platform = _SessionPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  test('后台登录保持 WebView 存活直到异步认证完成', () async {
    final login = BossSessionRunner.login(
      userName: 'test-user',
      password: 'test-password',
    );
    await platform.controller.firstProbe.future;
    await Future<void>.delayed(Duration.zero);
    expect(platform.view.disposed, isFalse);

    platform.controller.authenticated = true;
    expect((await login).ok, isTrue);
    expect(platform.view.disposed, isTrue);
  });

  test('错误密码不报成功，等待超时后释放 WebView', () async {
    final result = await BossSessionRunner.login(
      userName: 'test-user',
      password: 'wrong-password',
      timeout: const Duration(milliseconds: 100),
    );
    expect(result.ok, isFalse);
    expect(platform.view.disposed, isTrue);
  });

  test('后台业务操作也等待真实认证，不复用认证前请求', () async {
    var actionCalled = false;
    final operation = BossSessionRunner.run<String>((_) async {
      actionCalled = true;
      return 'completed';
    });
    await platform.controller.firstProbe.future;
    await Future<void>.delayed(Duration.zero);
    expect(actionCalled, isFalse);
    expect(platform.view.disposed, isFalse);

    platform.controller.authenticated = true;
    expect((await operation).value, 'completed');
    expect(actionCalled, isTrue);
    expect(platform.view.disposed, isTrue);
  });
  test('Cookie 已恢复同一账号时直接成功，不重复输入密码', () async {
    platform.controller.authenticated = true;
    platform.controller.alreadySignedIn = true;
    final result = await BossSessionRunner.login(
      userName: 'test-user',
      password: 'unused-password',
      timeout: const Duration(milliseconds: 100),
    );
    expect(result.ok, isTrue);
    expect(platform.controller.startCalls, 0);
    expect(platform.view.disposed, isTrue);
  });

  test('Cookie 属于其他账号时不会把该账号冒认为本次登录成功', () async {
    platform.controller.authenticated = true;
    platform.controller.userCode = 'other-user';
    final result = await BossSessionRunner.login(
      userName: 'test-user',
      password: 'test-password',
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('其他账号'));
    expect(platform.controller.startCalls, 0);
    expect(platform.view.disposed, isTrue);
  });

  test('服务端确定密码拒绝时立即返回原因并释放隐藏页面', () async {
    platform.controller.failureReason = 'passwordRejected';
    final result = await BossSessionRunner.login(
      userName: 'test-user',
      password: 'wrong-password',
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('密码不正确'));
    expect(result.message, isNot(contains('wrong-password')));
    expect(platform.view.disposed, isTrue);
  });

  test('加载接近上限仍给认证完整预算，且密码只提交一次', () async {
    platform.controller.pageDelay = const Duration(milliseconds: 700);
    platform.controller.authDelay = const Duration(milliseconds: 650);
    final result = await BossSessionRunner.login(
      userName: 'test-user',
      password: 'test-password',
      timeout: const Duration(milliseconds: 1200),
    );
    expect(result.ok, isTrue);
    expect(platform.controller.startCalls, 1);
    expect(platform.view.disposed, isTrue);
  });
}

class _SessionPlatform extends InAppWebViewPlatform {
  final controller = _SessionController();
  late _HeadlessSession view;

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) => view = _HeadlessSession(params, controller);
}

class _HeadlessSession extends PlatformHeadlessInAppWebView {
  _HeadlessSession(super.params, this.webViewController)
    : super.implementation();

  @override
  final _SessionController webViewController;
  bool disposed = false;

  @override
  Future<void> run() async {}

  @override
  Future<void> dispose() async => disposed = true;
}

class _SessionController extends PlatformInAppWebViewController {
  _SessionController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'session-test'),
      );

  bool authenticated = false;
  bool alreadySignedIn = false;
  String userCode = 'test-user';
  String? failureReason;
  Duration pageDelay = Duration.zero;
  Duration authDelay = Duration.zero;
  int startCalls = 0;
  bool delayApplied = false;
  final firstProbe = Completer<void>();

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('InforCenter_Platform_Login_LoginCheck')) {
      startCalls++;
      if (pageDelay > Duration.zero && !delayApplied) {
        delayApplied = true;
        await Future<void>.delayed(pageDelay);
      }
      if (alreadySignedIn) return '{"ok":false,"reason":"notReady"}';
      if (authDelay > Duration.zero) {
        Future<void>.delayed(authDelay, () => authenticated = true);
      }
      return '{"ok":true,"started":true}';
    }
    // 用户名解析和 TryLogin 请求先有 UserID，异步成功回调后才有 LoginID。
    final para = {
      'UserID': 'USERINFO_test',
      'UserCode': userCode,
      if (authenticated) 'LoginID': 'test-session',
    };
    final result = runJavaScript('''
      const document = { getElementById: () => ${!authenticated} ? {} : null };
      const window = {
        document,
        frames: [],
        __bossNativeLogin: ${jsonEncode({'phase': startCalls > 0 ? 'authenticating' : 'pageLoading', if (failureReason != null) 'reason': failureReason})},
        HoteamUI: { Security: { LoginPara: ${jsonEncode(para)} } },
        ${WorkLogRequestCapture.storeName}: [{body: ${jsonEncode(jsonEncode({'para': para}))}}]
      };
      const result = $source
      console.log(JSON.stringify(result));
    ''');
    if (!firstProbe.isCompleted) firstProbe.complete();
    return result;
  }
}
