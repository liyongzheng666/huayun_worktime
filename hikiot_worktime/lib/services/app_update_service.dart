import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_update_platform.dart';

typedef TemporaryDirectoryProvider = Future<Directory> Function();
typedef DownloadProgress = void Function(int receivedBytes, int? totalBytes);

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.installedVersion,
    required this.versionName,
    required this.versionCode,
    required this.releaseNotes,
    required this.releasePageUrl,
    required this.apkName,
    required this.apkDownloadUrl,
    required this.checksumDownloadUrl,
  });

  final InstalledAppVersion installedVersion;
  final String versionName;
  final int versionCode;
  final String releaseNotes;
  final Uri releasePageUrl;
  final String apkName;
  final Uri apkDownloadUrl;
  final Uri checksumDownloadUrl;

  String get displayVersion => '$versionName ($versionCode)';
}

class DownloadedAppUpdate {
  const DownloadedAppUpdate({required this.file, required this.sha256});

  final File file;
  final String sha256;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateService {
  AppUpdateService({
    http.Client? httpClient,
    AppUpdatePlatform? platform,
    TemporaryDirectoryProvider? temporaryDirectoryProvider,
    Duration timeout = const Duration(seconds: 5),
    Duration downloadIdleTimeout = const Duration(seconds: 15),
  }) : _httpClient = httpClient ?? http.Client(),
       platform = platform ?? MethodChannelAppUpdatePlatform(),
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _timeout = timeout,
       _downloadIdleTimeout = downloadIdleTimeout;

  static final Uri releasesPage = Uri.parse(
    'https://github.com/liyongzheng666/huayun_worktime/releases',
  );
  static final Uri _latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/liyongzheng666/huayun_worktime/releases/latest',
  );
  static final RegExp _apkNamePattern = RegExp(
    r'^huayun-worktime-v(\d+\.\d+\.\d+)\+(\d+)\.apk$',
  );
  static final RegExp _sha256Pattern = RegExp(r'^([a-fA-F0-9]{64})(?:\s|$)');

  final http.Client _httpClient;
  final TemporaryDirectoryProvider _temporaryDirectoryProvider;
  final Duration _timeout;
  final Duration _downloadIdleTimeout;
  final AppUpdatePlatform platform;

  bool get isSupported => platform.isSupported;

  Future<InstalledAppVersion> loadInstalledVersion() {
    return platform.loadInstalledVersion();
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!isSupported) return null;

    final installedVersion = await platform.loadInstalledVersion();
    final response = await _request(_latestReleaseApi);
    final decoded = _decodeObject(response.body);
    final assets = decoded['assets'];
    if (assets is! List) {
      throw const AppUpdateException('GitHub Release 缺少安装包列表');
    }

    Map<String, Object?>? apkAsset;
    RegExpMatch? versionMatch;
    for (final rawAsset in assets) {
      if (rawAsset is! Map) continue;
      final asset = rawAsset.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final name = asset['name'];
      if (name is! String) continue;
      final match = _apkNamePattern.firstMatch(name);
      if (match == null) continue;
      apkAsset = asset;
      versionMatch = match;
      break;
    }

    if (apkAsset == null || versionMatch == null) {
      throw const AppUpdateException('最新 Release 中没有符合命名规则的 APK');
    }

    final versionName = versionMatch.group(1)!;
    final versionCode = int.parse(versionMatch.group(2)!);
    final expectedTag = 'v$versionName+$versionCode';
    if (decoded['tag_name'] != expectedTag) {
      throw const AppUpdateException('Release tag 与 APK 版本不一致');
    }

    final checksumName = '${apkAsset['name']}.sha256';
    Map<String, Object?>? checksumAsset;
    for (final rawAsset in assets) {
      if (rawAsset is! Map) continue;
      final asset = rawAsset.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (asset['name'] == checksumName) {
        checksumAsset = asset;
        break;
      }
    }
    if (checksumAsset == null) {
      throw const AppUpdateException('最新 Release 缺少 SHA-256 校验文件');
    }

    if (versionCode <= installedVersion.versionCode) return null;

    final apkUrl = _readGitHubDownloadUrl(apkAsset);
    final checksumUrl = _readGitHubDownloadUrl(checksumAsset);
    final releasePageUrl = _readHttpsUrl(decoded['html_url'], 'Release 页面地址无效');

    return AppUpdateInfo(
      installedVersion: installedVersion,
      versionName: versionName,
      versionCode: versionCode,
      releaseNotes: (decoded['body'] as String?)?.trim() ?? '',
      releasePageUrl: releasePageUrl,
      apkName: apkAsset['name']! as String,
      apkDownloadUrl: apkUrl,
      checksumDownloadUrl: checksumUrl,
    );
  }

  Future<DownloadedAppUpdate> downloadUpdate(
    AppUpdateInfo update, {
    DownloadProgress? onProgress,
  }) async {
    final checksumResponse = await _request(update.checksumDownloadUrl);
    final checksumMatch = _sha256Pattern.firstMatch(
      checksumResponse.body.trim(),
    );
    if (checksumMatch == null) {
      throw const AppUpdateException('SHA-256 校验文件格式错误');
    }
    final sha256 = checksumMatch.group(1)!.toLowerCase();

    final temporaryDirectory = await _temporaryDirectoryProvider();
    final updateDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}updates',
    );
    await updateDirectory.create(recursive: true);
    final target = File(
      '${updateDirectory.path}${Platform.pathSeparator}${update.apkName}',
    );
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    IOSink? sink;
    try {
      final request = http.Request('GET', update.apkDownloadUrl);
      request.headers.addAll(_headers);
      final response = await _httpClient
          .send(request)
          .timeout(_downloadIdleTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('APK 下载失败（HTTP ${response.statusCode}）');
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;
      sink = partial.openWrite();
      await for (final chunk in response.stream.timeout(_downloadIdleTimeout)) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes, totalBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      return DownloadedAppUpdate(file: target, sha256: sha256);
    } on AppUpdateException {
      rethrow;
    } on TimeoutException {
      throw const AppUpdateException('下载更新超时，请检查网络后重试');
    } catch (_) {
      throw const AppUpdateException('下载更新失败，请检查网络后重试');
    } finally {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<bool> canRequestPackageInstalls() {
    return platform.canRequestPackageInstalls();
  }

  Future<void> cleanupStaleDownloads({
    Duration maxAge = const Duration(days: 7),
  }) async {
    final temporaryDirectory = await _temporaryDirectoryProvider();
    final updateDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}updates',
    );
    if (!await updateDirectory.exists()) return;

    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in updateDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.apk') && !name.endsWith('.apk.part')) continue;
      final modified = await entity.lastModified();
      if (modified.isBefore(cutoff)) await entity.delete();
    }
  }

  Future<void> openInstallPermissionSettings() {
    return platform.openInstallPermissionSettings();
  }

  Future<ApkInstallResult> installDownloadedUpdate(DownloadedAppUpdate update) {
    return platform.verifyAndInstallApk(
      path: update.file.path,
      expectedSha256: update.sha256,
    );
  }

  Future<http.Response> _request(Uri uri) async {
    try {
      final response = await _httpClient
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode == HttpStatus.notFound) {
        throw const AppUpdateException('GitHub 尚未发布可用版本');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('检查更新失败（HTTP ${response.statusCode}）');
      }
      return response;
    } on AppUpdateException {
      rethrow;
    } on TimeoutException {
      throw const AppUpdateException('连接 GitHub 超时');
    } catch (_) {
      throw const AppUpdateException('暂时无法连接 GitHub');
    }
  }

  Map<String, Object?> _decodeObject(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // 统一转为用户可理解的 Release 格式错误。
    }
    throw const AppUpdateException('GitHub Release 返回格式错误');
  }

  Uri _readGitHubDownloadUrl(Map<String, Object?> asset) {
    return _readHttpsUrl(asset['browser_download_url'], 'Release 下载地址无效');
  }

  Uri _readHttpsUrl(Object? rawValue, String errorMessage) {
    if (rawValue is! String) throw AppUpdateException(errorMessage);
    final uri = Uri.tryParse(rawValue);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      throw AppUpdateException(errorMessage);
    }
    return uri;
  }

  Map<String, String> get _headers => const {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'huayun-worktime-android-updater',
  };
}
