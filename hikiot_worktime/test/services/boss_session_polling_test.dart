import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_credentials_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PollingPlatform platform;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'team', personNo: 'person');
    await BossCredentialsService(storage: storage).bindCurrentSession();
    platform = _PollingPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  test('业务会话在10ms后就绪，不额外等待固定500ms', () async {
    final watch = Stopwatch()..start();
    final result = await BossSessionRunner.run<String>((_) async => 'read');
    expect(result.value, 'read');
    expect(watch.elapsedMilliseconds, lessThan(250));
    expect(platform.view.disposed, isTrue);
  });

  test('登录后10ms完成认证，不额外等待固定500ms', () async {
    final watch = Stopwatch()..start();
    final result = await BossSessionRunner.login(
      userName: 'fake-user',
      password: 'fake-password',
    );
    expect(result.ok, isTrue);
    expect(result.passwordAuthenticated, isTrue);
    expect(watch.elapsedMilliseconds, lessThan(250));
    expect(platform.view.disposed, isTrue);
  });

  test('轮询等待不越过短截止时间，长等待在首秒后退避', () async {
    platform.readyAfter = const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    final result = await BossSessionRunner.run<String>(
      (_) async => 'unexpected',
      timeout: const Duration(milliseconds: 35),
    );
    expect(result.status, BossSessionStatus.noSession);
    expect(watch.elapsedMilliseconds, lessThan(200));
    expect(platform.view.disposed, isTrue);

    watch.reset();
    final login = await BossSessionRunner.login(
      userName: 'fake-user',
      password: 'fake-password',
      timeout: const Duration(milliseconds: 35),
    );
    expect(login.ok, isFalse);
    expect(watch.elapsedMilliseconds, lessThan(200));
    expect(platform.view.disposed, isTrue);

    platform.probes = 0;
    await BossSessionRunner.run<String>(
      (_) async => 'unexpected',
      timeout: const Duration(milliseconds: 1300),
    );
    // 首秒快速探测，之后回到500ms，不能整个超时一直100ms扫描。
    expect(platform.probes, inInclusiveRange(8, 12));
    expect(platform.view.disposed, isTrue);
  });
}

class _PollingPlatform extends InAppWebViewPlatform {
  Duration readyAfter = const Duration(milliseconds: 10);
  int probes = 0;
  late _PollingView view;
  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) => view = _PollingView(params, this);
}

class _PollingView extends PlatformHeadlessInAppWebView {
  _PollingView(super.params, _PollingPlatform platform)
    : webViewController = _PollingController(platform),
      super.implementation();
  @override
  final _PollingController webViewController;
  bool disposed = false;
  @override
  Future<void> run() async => webViewController.watch.start();
  @override
  Future<void> dispose() async => disposed = true;
}

class _PollingController extends PlatformInAppWebViewController {
  _PollingController(this.platform)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'polling'),
      );
  final _PollingPlatform platform;
  final watch = Stopwatch();
  bool started = false;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('InforCenter_Platform_Login_LoginCheck')) {
      started = true;
      return '{"ok":true,"started":true}';
    }
    platform.probes++;
    final ready = watch.elapsed >= platform.readyAfter;
    return jsonEncode({
      'ready': ready,
      'needsLogin': false,
      'phase': ready
          ? 'businessSession'
          : started
          ? 'authenticating'
          : 'pageLoading',
    });
  }
}
