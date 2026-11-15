import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_login_coordinator.dart';
import 'package:hikiot_worktime/services/boss_credentials_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryLoginPlatform extends InAppWebViewPlatform {
  bool authenticated = false;
  int loginCalls = 0;
  String? failure;

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) => _MemoryHeadless(params, _MemoryController(this));
}

class _MemoryHeadless extends PlatformHeadlessInAppWebView {
  _MemoryHeadless(super.params, this.webViewController)
    : super.implementation();
  @override
  final _MemoryController webViewController;
  @override
  Future<void> run() async {}
  @override
  Future<void> dispose() async {}
}

class _MemoryController extends PlatformInAppWebViewController {
  _MemoryController(this.platform)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'memory'),
      );
  final _MemoryLoginPlatform platform;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('InforCenter_Platform_Login_LoginCheck')) {
      platform.loginCalls++;
      if (platform.failure != null) {
        return '{"ok":false,"reason":"passwordRejected"}';
      }
      platform.authenticated = true;
      return '{"ok":true,"started":true}';
    }
    return platform.authenticated
        ? '{"ready":true,"phase":"businessSession"}'
        : '{"ready":false,"phase":"pageLoading","needsLogin":true}';
  }
}

class _LoginHarness {
  final storage = StorageService();
  late final credentials = BossCredentialsService(storage: storage);
  var platform = _MemoryLoginPlatform();
  final results = <bool>[];

  Future<void> mount(WidgetTester tester, {bool forceManual = false}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'test-team', personNo: 'test-person');
    InAppWebViewPlatform.instance = platform;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                results.add(
                  await BossLoginCoordinator.prompt(
                    context: context,
                    openWeb: () async {},
                    forceManual: forceManual,
                    credentialsService: credentials,
                  ),
                );
              },
              child: const Text('请求后台登录'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> request(WidgetTester tester) async {
    await tester.tap(find.text('请求后台登录'));
    await flush(tester);
  }

  Future<void> submit(
    WidgetTester tester,
    String password, {
    bool remember = true,
  }) async {
    await tester.enterText(find.byType(TextField).at(0), 'boss-user');
    await tester.enterText(find.byType(TextField).at(1), password);
    if (!remember) {
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
    }
    await tester.pump();
    await tester.tap(find.text('后台登录'));
    await flush(tester);
  }
}

void main() {
  testWidgets('首次记住后新建冷启动WebView且Cookie失效仍无需重输密码', (tester) async {
    final h = _LoginHarness();
    await h.mount(tester);
    await h.request(tester);
    await h.submit(tester, 'test-password');
    expect(h.results, [true]);
    expect(h.platform.loginCalls, 1);
    h.platform = _MemoryLoginPlatform();
    InAppWebViewPlatform.instance = h.platform;
    await h.request(tester);
    expect(find.text('登录 BOSS'), findsNothing);
    expect(h.results, [true, true]);
    expect(h.platform.loginCalls, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().map(prefs.get).toString(),
      isNot(contains('test-password')),
    );
  });

  testWidgets('Cookie已就绪但本次输入未验证，不把错误新密码存入安全存储', (tester) async {
    final h = _LoginHarness();
    await h.mount(tester, forceManual: true);
    h.platform.authenticated = true;
    await h.request(tester);
    await h.submit(tester, 'unverified-wrong-password');
    expect(h.results, [true]);
    expect(h.platform.loginCalls, 0);
    expect(await h.credentials.loadForCurrentScope(), isNull);
    expect(find.textContaining('未经过认证，未保存新密码'), findsOneWidget);
  });

  testWidgets('复用Cookie不会用未校验输入覆盖原来已验证的记忆', (tester) async {
    final h = _LoginHarness();
    await h.mount(tester, forceManual: true);
    await h.credentials.rememberForCurrentScope(
      userName: 'boss-user',
      password: 'previously-verified',
    );
    h.platform.authenticated = true;
    await h.request(tester);
    await h.submit(tester, 'unverified-wrong-password');
    expect(h.platform.loginCalls, 0);
    expect(
      (await h.credentials.loadForCurrentScope())?.password,
      'previously-verified',
    );
    expect(h.results, [true]);
  });

  testWidgets('取消记住密码后仅本次登录，冷启动Cookie失效时回手工面板', (tester) async {
    final h = _LoginHarness();
    await h.mount(tester);
    await h.request(tester);
    await h.submit(tester, 'test-password', remember: false);
    expect(h.results, [true]);
    expect(await h.credentials.loadForCurrentScope(), isNull);
    h.platform = _MemoryLoginPlatform();
    InAppWebViewPlatform.instance = h.platform;
    await h.request(tester);
    expect(find.text('登录 BOSS'), findsOneWidget);
    expect(h.platform.loginCalls, 0);
    await tester.tap(find.text('取消'));
    await h.flush(tester);
  });
}
