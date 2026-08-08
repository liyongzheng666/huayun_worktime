import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/app_update_platform.dart';
import 'package:hikiot_worktime/services/app_update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'huayun-update-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('AppUpdateService.checkForUpdate', () {
    test('按 Android versionCode 发现更高版本', () async {
      final service = _service(
        temporaryDirectory: temporaryDirectory,
        response: _releaseResponse(versionCode: 4),
      );

      final update = await service.checkForUpdate();

      expect(update, isNotNull);
      expect(update!.versionName, '2.4.0');
      expect(update.versionCode, 4);
      expect(update.apkName, 'huayun-worktime-v2.4.0+4.apk');
      expect(update.releaseNotes, '修复若干问题');
      expect(update.installedVersion.displayName, '2.3.1 (3)');
    });

    test('远端 versionCode 没有增加时视为最新', () async {
      final service = _service(
        temporaryDirectory: temporaryDirectory,
        response: _releaseResponse(versionCode: 3),
      );

      expect(await service.checkForUpdate(), isNull);
    });

    test('拒绝 tag 与 APK 版本不一致的 Release', () async {
      final service = _service(
        temporaryDirectory: temporaryDirectory,
        response: _releaseResponse(versionCode: 4, tagName: 'v2.4.0+5'),
      );

      await expectLater(
        service.checkForUpdate(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('版本不一致'),
          ),
        ),
      );
    });

    test('缺少同名 SHA-256 文件时拒绝更新', () async {
      final service = _service(
        temporaryDirectory: temporaryDirectory,
        response: _releaseResponse(versionCode: 4, includeChecksum: false),
      );

      await expectLater(
        service.checkForUpdate(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
    });

    test('GitHub 无 Release 时返回可理解的错误', () async {
      final service = AppUpdateService(
        httpClient: MockClient((_) async => http.Response('', 404)),
        platform: _FakeUpdatePlatform(),
        temporaryDirectoryProvider: () async => temporaryDirectory,
      );

      await expectLater(
        service.checkForUpdate(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('尚未发布'),
          ),
        ),
      );
    });

    test('超过时限后结束检查，不拖住启动流程', () async {
      final service = AppUpdateService(
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return _releaseResponse(versionCode: 4);
        }),
        platform: _FakeUpdatePlatform(),
        temporaryDirectoryProvider: () async => temporaryDirectory,
        timeout: const Duration(milliseconds: 1),
      );

      await expectLater(
        service.checkForUpdate(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    });
  });

  group('AppUpdateService.downloadUpdate', () {
    test('下载 APK 到隔离缓存并报告进度', () async {
      final apkBytes = utf8.encode('signed apk bytes');
      const sha256 =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final client = MockClient((request) async {
        if (request.url.path.endsWith('.sha256')) {
          return http.Response('$sha256  huayun-worktime-v2.4.0+4.apk\n', 200);
        }
        return http.Response.bytes(apkBytes, 200);
      });
      final service = AppUpdateService(
        httpClient: client,
        platform: _FakeUpdatePlatform(),
        temporaryDirectoryProvider: () async => temporaryDirectory,
      );
      int? receivedBytes;
      int? totalBytes;

      final downloaded = await service.downloadUpdate(
        _updateInfo(),
        onProgress: (received, total) {
          receivedBytes = received;
          totalBytes = total;
        },
      );

      expect(await downloaded.file.readAsBytes(), apkBytes);
      expect(downloaded.file.parent.path, endsWith('updates'));
      expect(downloaded.sha256, sha256);
      expect(receivedBytes, apkBytes.length);
      expect(totalBytes, apkBytes.length);
    });

    test('校验文件格式错误时不创建 APK', () async {
      final service = AppUpdateService(
        httpClient: MockClient((_) async => http.Response('not-a-hash', 200)),
        platform: _FakeUpdatePlatform(),
        temporaryDirectoryProvider: () async => temporaryDirectory,
      );

      await expectLater(
        service.downloadUpdate(_updateInfo()),
        throwsA(isA<AppUpdateException>()),
      );
      expect(
        Directory('${temporaryDirectory.path}/updates').existsSync(),
        isFalse,
      );
    });
  });

  test('只清理超过期限的 APK 缓存，不碰其它临时文件', () async {
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final staleApk = File('${updateDirectory.path}/old.apk')
      ..writeAsStringSync('old');
    final freshApk = File('${updateDirectory.path}/new.apk')
      ..writeAsStringSync('new');
    final unrelated = File('${updateDirectory.path}/note.txt')
      ..writeAsStringSync('keep');
    staleApk.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 8)),
    );
    final service = AppUpdateService(
      httpClient: MockClient((_) async => http.Response('', 200)),
      platform: _FakeUpdatePlatform(),
      temporaryDirectoryProvider: () async => temporaryDirectory,
    );

    await service.cleanupStaleDownloads();

    expect(staleApk.existsSync(), isFalse);
    expect(freshApk.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
  });
}

AppUpdateService _service({
  required Directory temporaryDirectory,
  required http.Response response,
}) {
  return AppUpdateService(
    httpClient: MockClient((_) async => response),
    platform: _FakeUpdatePlatform(),
    temporaryDirectoryProvider: () async => temporaryDirectory,
  );
}

http.Response _releaseResponse({
  required int versionCode,
  String? tagName,
  bool includeChecksum = true,
}) {
  final apkName = 'huayun-worktime-v2.4.0+$versionCode.apk';
  final assets = <Map<String, Object?>>[
    {
      'name': apkName,
      'browser_download_url':
          'https://github.com/liyongzheng666/huayun_worktime/releases/download/v2.4.0+$versionCode/$apkName',
    },
    if (includeChecksum)
      {
        'name': '$apkName.sha256',
        'browser_download_url':
            'https://github.com/liyongzheng666/huayun_worktime/releases/download/v2.4.0+$versionCode/$apkName.sha256',
      },
  ];
  return http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'tag_name': tagName ?? 'v2.4.0+$versionCode',
        'html_url':
            'https://github.com/liyongzheng666/huayun_worktime/releases/tag/v2.4.0+$versionCode',
        'body': '修复若干问题',
        'assets': assets,
      }),
    ),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

AppUpdateInfo _updateInfo() {
  return AppUpdateInfo(
    installedVersion: const InstalledAppVersion(
      versionName: '2.3.1',
      versionCode: 3,
    ),
    versionName: '2.4.0',
    versionCode: 4,
    releaseNotes: '修复若干问题',
    releasePageUrl: Uri.parse(
      'https://github.com/liyongzheng666/huayun_worktime/releases/tag/v2.4.0+4',
    ),
    apkName: 'huayun-worktime-v2.4.0+4.apk',
    apkDownloadUrl: Uri.parse(
      'https://github.com/liyongzheng666/huayun_worktime/releases/download/v2.4.0+4/huayun-worktime-v2.4.0+4.apk',
    ),
    checksumDownloadUrl: Uri.parse(
      'https://github.com/liyongzheng666/huayun_worktime/releases/download/v2.4.0+4/huayun-worktime-v2.4.0+4.apk.sha256',
    ),
  );
}

class _FakeUpdatePlatform implements AppUpdatePlatform {
  @override
  bool get isSupported => true;

  @override
  Future<bool> canRequestPackageInstalls() async => true;

  @override
  Future<InstalledAppVersion> loadInstalledVersion() async {
    return const InstalledAppVersion(versionName: '2.3.1', versionCode: 3);
  }

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<ApkInstallResult> verifyAndInstallApk({
    required String path,
    required String expectedSha256,
  }) async {
    return ApkInstallResult.launched;
  }
}
