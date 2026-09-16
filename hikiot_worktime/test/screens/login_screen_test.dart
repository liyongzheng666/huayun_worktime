import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/main.dart' show SplashScreen;
import 'package:hikiot_worktime/screens/login_screen.dart';
import 'package:hikiot_worktime/services/session_service.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestCookieManager extends PlatformCookieManager {
  _TestCookieManager()
    : super.implementation(const PlatformCookieManagerCreationParams());

  bool fail = false;
  int clearCalls = 0;
  Completer<void>? gate;

  @override
  Future<bool> deleteAllCookies() async {
    clearCalls++;
    await gate?.future;
    if (fail) throw StateError('Cookie store failed');
    return true;
  }

  @override
  Future<bool> deleteCookies({
    required WebUri url,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => true;
}

class _TestWebView extends PlatformInAppWebViewWidget {
  _TestWebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const Text('登录网页');

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

class _TestWebViewPlatform extends InAppWebViewPlatform {
  _TestWebViewPlatform(this.cookies);

  final _TestCookieManager cookies;

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _TestWebView(params);
}

void main() {
  final cookies = _TestCookieManager();

  setUpAll(() {
    InAppWebViewPlatform.instance = _TestWebViewPlatform(cookies);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies.fail = false;
    cookies.clearCalls = 0;
    cookies.gate = null;
  });

  testWidgets('重新登录时 Cookie 清理失败给出重试，重试成功才加载网页', (tester) async {
    cookies.fail = true;
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen(forceLogout: true)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('清理登录状态失败，请重试。'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('登录网页'), findsNothing);
    expect(cookies.clearCalls, 1);

    cookies.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(cookies.clearCalls, 2);
    expect(find.text('登录海康互联'), findsOneWidget);
    expect(find.text('登录网页'), findsOneWidget);
    expect(find.text('清理登录状态失败，请重试。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认登录入口先清理 Cookie，再加载网页登录', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    expect(find.text('登录网页'), findsOneWidget);
    expect(cookies.clearCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出清理失败后重启，无 token 入口仍清理旧 Cookie 并允许重试', (tester) async {
    final storage = StorageService();
    await storage.saveToken('expired-token');
    await storage.saveDisclaimerAccepted(true);
    await SessionService(
      storage: storage,
      remoteLogout: (_) async {},
      clearWebSession: () async => throw StateError('Cookie store failed'),
    ).logout();
    expect(await storage.loadToken(), isNull);

    cookies.fail = true;
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(cookies.clearCalls, 1);
    expect(find.text('清理登录状态失败，请重试。'), findsOneWidget);
    expect(find.text('登录网页'), findsNothing);

    cookies.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(cookies.clearCalls, 2);
    expect(find.text('登录网页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理尚未完成时离开登录页，完成后不再更新已销毁页面', (tester) async {
    cookies.gate = Completer<void>();
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen(forceLogout: true)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    cookies.gate!.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
