import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/app_update_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('通过原生通道读取版本并打开安装器', () async {
    const channel = MethodChannel('test_app_update');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getAppVersion' => {'versionName': '2.4.0', 'versionCode': 4},
            'canRequestPackageInstalls' => true,
            'verifyAndInstallApk' => 'launched',
            _ => null,
          };
        });
    final platform = MethodChannelAppUpdatePlatform(
      channel: channel,
      isAndroid: true,
    );

    expect((await platform.loadInstalledVersion()).displayName, '2.4.0 (4)');
    expect(await platform.canRequestPackageInstalls(), isTrue);
    expect(
      await platform.verifyAndInstallApk(
        path: '/cache/updates/app.apk',
        expectedSha256: 'abc',
      ),
      ApkInstallResult.launched,
    );
    await platform.openInstallPermissionSettings();

    expect(calls.map((call) => call.method), [
      'getAppVersion',
      'canRequestPackageInstalls',
      'verifyAndInstallApk',
      'openInstallPermissionSettings',
    ]);
  });

  test('非 Android 平台不启用 APK 更新', () async {
    final platform = MethodChannelAppUpdatePlatform(isAndroid: false);

    expect(platform.isSupported, isFalse);
    await expectLater(
      platform.loadInstalledVersion(),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
