import 'dart:async';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/boss_credentials_service.dart';
import 'package:hikiot_worktime/services/boss_session_runner.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecoveryPlatform extends InAppWebViewPlatform {
  bool cookieAuthenticated = false;
  String? rejection;
  int passwordsSent = 0;
  int probes = 0;
  final passwordStarted = Completer<void>();
  Completer<void>? authenticationGate;
  final views = <_RecoveryView>[];
  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) {
    final view = _RecoveryView(params, _RecoveryController(this));
    views.add(view);
    return view;
  }
}

class _RecoveryView extends PlatformHeadlessInAppWebView {
  _RecoveryView(super.params, this.webViewController) : super.implementation();
  @override
  final _RecoveryController webViewController;
  bool disposed = false;
  @override
  Future<void> run() async {}
  @override
  Future<void> dispose() async => disposed = true;
}

class _RecoveryController extends PlatformInAppWebViewController {
  _RecoveryController(this.platform)
    : authenticated = platform.cookieAuthenticated,
      super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'recovery'),
      );
  final _RecoveryPlatform platform;
  bool authenticated;
  bool requested = false;
  @override
  Future<void> reload() async {
    authenticated = platform.cookieAuthenticated;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('InforCenter_Platform_Login_LoginCheck')) {
      requested = true;
      platform.passwordsSent++;
      if (!platform.passwordStarted.isCompleted) {
        platform.passwordStarted.complete();
      }
      if (platform.rejection == null) {
        if (platform.authenticationGate == null) {
          authenticated = true;
          platform.cookieAuthenticated = true;
        } else {
          unawaited(
            platform.authenticationGate!.future.then((_) {
              authenticated = true;
              platform.cookieAuthenticated = true;
            }),
          );
        }
      }
      return '{"ok":true,"started":true}';
    }
    platform.probes++;
    return jsonEncode({
      'ready': authenticated,
      'phase': authenticated
          ? 'businessSession'
          : requested
          ? 'authenticating'
          : 'pageLoading',
      'needsLogin': !requested && !authenticated,
      if (requested && platform.rejection != null) 'reason': platform.rejection,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late BossCredentialsService credentials;
  late _RecoveryPlatform platform;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = StorageService();
    await storage.saveToken('test-token');
    await storage.saveTeamContext(teamNo: 'team', personNo: 'person');
    credentials = BossCredentialsService(storage: storage);
    platform = _RecoveryPlatform();
    InAppWebViewPlatform.instance = platform;
  });
  Future<void> remember() => credentials.rememberForCurrentScope(
    userName: 'test-user',
    password: 'fake-password',
  );
  test('明确登录页立即返回noSession，不空轮询20秒', () async {
    await credentials.bindCurrentSession();
    var actions = 0;
    final result = await BossSessionRunner.run<String>((_) async {
      actions++;
      return 'not-called';
    }, credentialsService: credentials);
    expect(result.status, BossSessionStatus.noSession);
    expect(actions, 0);
    expect(platform.probes, 1);
    expect(platform.views.single.disposed, isTrue);
  });
  test('Cookie失效后只认证一次，再执行原业务一次', () async {
    await remember();
    var actions = 0;
    final result = await BossSessionRunner.run<String>((_) async {
      actions++;
      return 'done';
    }, credentialsService: credentials);
    expect(result.value, 'done');
    expect(actions, 1);
    expect(platform.passwordsSent, 1);
    expect(await credentials.isCurrentSessionBound(), isTrue);
  });
  test('两个独立WebView并发恢复共用一次密码认证，各自业务只跑一次', () async {
    await remember();
    platform.authenticationGate = Completer<void>();
    var actions = 0;
    Future<BossSessionResult<String>> run() =>
        BossSessionRunner.run<String>((_) async {
          actions++;
          return 'done';
        }, credentialsService: credentials);
    final first = run();
    final second = run();
    await platform.passwordStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(platform.passwordsSent, 1);
    platform.authenticationGate!.complete();
    final results = await Future.wait([first, second]);
    expect(results.every((result) => result.value == 'done'), isTrue);
    expect(actions, 2);
    expect(platform.passwordsSent, 1);
    expect(platform.views.length, 2);
  });
  for (final reason in ['passwordRejected', 'accountLocked', 'requiresWeb']) {
    test('$reason停用自动登录，下次后台请求不再次发送密码', () async {
      await remember();
      platform.rejection = reason;
      var actions = 0;
      Future<BossSessionResult<String>> run() =>
          BossSessionRunner.run<String>((_) async {
            actions++;
            return 'not-called';
          }, credentialsService: credentials);
      expect((await run()).status, BossSessionStatus.noSession);
      expect(
        (await credentials.loadForCurrentScope())?.automaticLoginEnabled,
        isFalse,
      );
      expect((await run()).status, BossSessionStatus.noSession);
      expect(platform.passwordsSent, 1);
      expect(actions, 0);
    });
  }
  test('业务已开始后的异常不通过恢复机制重放保存', () async {
    await remember();
    platform.cookieAuthenticated = true;
    var actions = 0;
    final result = await BossSessionRunner.run<String>((_) async {
      actions++;
      throw StateError('模拟未知写入结果');
    }, credentialsService: credentials);
    expect(result.status, BossSessionStatus.failed);
    expect(actions, 1);
    expect(platform.passwordsSent, 0);
  });
  test('业务读取期间主账号变化，拒绝旧数据返回且不重跑业务', () async {
    await remember();
    platform.cookieAuthenticated = true;
    var actions = 0;
    final result = await BossSessionRunner.run<String>((_) async {
      actions++;
      await storage.saveToken('new-user-token');
      await storage.saveTeamContext(teamNo: 'team', personNo: 'new-person');
      return 'old-account-data';
    }, credentialsService: credentials);
    expect(result.status, BossSessionStatus.failed);
    expect(result.value, isNull);
    expect(actions, 1);
  });
}
