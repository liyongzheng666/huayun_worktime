import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class InstalledAppVersion {
  const InstalledAppVersion({
    required this.versionName,
    required this.versionCode,
  });

  final String versionName;
  final int versionCode;

  String get displayName => '$versionName ($versionCode)';
}

enum ApkInstallResult { launched, permissionRequired }

abstract class AppUpdatePlatform {
  bool get isSupported;

  Future<InstalledAppVersion> loadInstalledVersion();

  Future<bool> canRequestPackageInstalls();

  Future<void> openInstallPermissionSettings();

  Future<ApkInstallResult> verifyAndInstallApk({
    required String path,
    required String expectedSha256,
  });
}

class MethodChannelAppUpdatePlatform implements AppUpdatePlatform {
  MethodChannelAppUpdatePlatform({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ?? const MethodChannel('com.hikiot.worktime/app_update'),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  bool get isSupported => _isAndroid;

  @override
  Future<InstalledAppVersion> loadInstalledVersion() async {
    _ensureSupported();
    final value = await _channel.invokeMapMethod<String, Object?>(
      'getAppVersion',
    );
    final versionName = value?['versionName'];
    final versionCode = value?['versionCode'];
    if (versionName is! String || versionCode is! num) {
      throw const FormatException('无法读取当前应用版本');
    }
    return InstalledAppVersion(
      versionName: versionName,
      versionCode: versionCode.toInt(),
    );
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    _ensureSupported();
    return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
        false;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    _ensureSupported();
    await _channel.invokeMethod<void>('openInstallPermissionSettings');
  }

  @override
  Future<ApkInstallResult> verifyAndInstallApk({
    required String path,
    required String expectedSha256,
  }) async {
    _ensureSupported();
    final status = await _channel.invokeMethod<String>('verifyAndInstallApk', {
      'path': path,
      'expectedSha256': expectedSha256,
    });
    return switch (status) {
      'launched' => ApkInstallResult.launched,
      'permissionRequired' => ApkInstallResult.permissionRequired,
      _ => throw const FormatException('系统没有返回有效的安装状态'),
    };
  }

  void _ensureSupported() {
    if (!_isAndroid) {
      throw UnsupportedError('APK 更新仅支持 Android');
    }
  }
}
