import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_service.dart';

/// 密码对象只在认证流程使用，不实现包含内容的 toString。
class BossSavedCredentials {
  const BossSavedCredentials({
    required this.scope,
    required this.userName,
    required this.password,
    required this.automaticLoginEnabled,
  });

  final String scope;
  final String userName;
  final String password;
  final bool automaticLoginEnabled;
}

/// 按已验证的主账号保存 BOSS 凭据；SharedPreferences 仅保留停用标记。
class BossCredentialsService {
  BossCredentialsService({
    StorageService? storage,
    FlutterSecureStorage? secureStorage,
    DateTime Function()? now,
  }) : _storage = storage ?? StorageService(),
       _secure =
           secureStorage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked_this_device,
             ),
           ),
       _now = now ?? DateTime.now;

  final StorageService _storage;
  final FlutterSecureStorage _secure;
  final DateTime Function() _now;
  static const _prefix = 'huayun.boss.credentials.v1.';
  static const _enabledPrefix = 'boss_auto_login_enabled.';
  static const _lastScopeKey = 'boss_last_credential_scope';
  static const _sessionScopeKey = 'boss_authenticated_app_scope';
  static final Map<String, DateTime> _lastAutomaticAttempt = {};

  Future<String?> currentScope() => _storage.loadBossCredentialScope();

  static String _suffix(String scope) => base64Url.encode(utf8.encode(scope));

  Future<BossSavedCredentials?> loadForCurrentScope() async {
    final scope = await currentScope();
    if (scope == null) return null;
    try {
      final value = await _secure.read(key: '$_prefix${_suffix(scope)}');
      if (value == null) return null;
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded['scope'] != scope ||
          decoded['userName'] is! String ||
          decoded['password'] is! String ||
          (decoded['userName'] as String).trim().isEmpty ||
          (decoded['password'] as String).isEmpty) {
        return null;
      }
      if (await currentScope() != scope) return null;
      final prefs = await SharedPreferences.getInstance();
      return BossSavedCredentials(
        scope: scope,
        userName: (decoded['userName'] as String).trim(),
        password: decoded['password'] as String,
        automaticLoginEnabled:
            prefs.getBool('$_enabledPrefix${_suffix(scope)}') == true,
      );
    } catch (_) {
      // 安全存储锁定/不可用时回到手工流程，不把异常或凭据写入日志。
      return null;
    }
  }

  Future<void> rememberForCurrentScope({
    required String userName,
    required String password,
    String? expectedScope,
  }) async {
    final scope = await currentScope();
    if (scope == null || (expectedScope != null && scope != expectedScope)) {
      throw StateError('当前主账号身份尚未确认或已变化');
    }
    if (userName.trim().isEmpty || password.isEmpty) {
      throw ArgumentError('账号密码不能为空');
    }
    final prefs = await SharedPreferences.getInstance();
    final enabledKey = '$_enabledPrefix${_suffix(scope)}';
    // 写入完成前保持停用，避免部分失败留下可自动使用的旧密码。
    if (!await prefs.setBool(enabledKey, false)) throw StateError('无法保存自动登录设置');
    await _secure.write(
      key: '$_prefix${_suffix(scope)}',
      value: jsonEncode({
        'scope': scope,
        'userName': userName.trim(),
        'password': password,
      }),
    );
    if (await currentScope() != scope) throw StateError('主账号已变化，请重新确认登录');
    if (!await prefs.setString(_lastScopeKey, scope) ||
        !await prefs.setBool(enabledKey, true)) {
      throw StateError('无法启用自动登录');
    }
    _lastAutomaticAttempt.remove(scope);
  }

  /// 停用标记先持久化；即使 Keychain 删除失败也不会继续自动使用。
  Future<void> forgetCurrentScope() async {
    final prefs = await SharedPreferences.getInstance();
    final scope = await currentScope() ?? prefs.getString(_lastScopeKey);
    if (scope == null) return;
    if (!await prefs.setBool('$_enabledPrefix${_suffix(scope)}', false)) {
      throw StateError('无法关闭自动登录');
    }
    _lastAutomaticAttempt.remove(scope);
    await prefs.remove(_sessionScopeKey);
    await _secure.delete(key: '$_prefix${_suffix(scope)}');
    if (prefs.getString(_lastScopeKey) == scope) {
      await prefs.remove(_lastScopeKey);
    }
  }

  Future<void> disableAutomaticLogin(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('$_enabledPrefix${_suffix(scope)}', false)) {
      throw StateError('无法停用自动登录');
    }
  }

  /// 超时或网络错误在本进程内退避，密码拒绝等确定错误由停用标记阻止重试。
  bool claimAutomaticAttempt(BossSavedCredentials credentials) {
    if (!credentials.automaticLoginEnabled) return false;
    final now = _now();
    final previous = _lastAutomaticAttempt[credentials.scope];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 5)) {
      return false;
    }
    _lastAutomaticAttempt[credentials.scope] = now;
    return true;
  }

  Future<void> bindCurrentSession({String? expectedScope}) async {
    final scope = await currentScope();
    if (scope == null || (expectedScope != null && scope != expectedScope)) {
      throw StateError('主账号已变化，请重新确认登录');
    }
    final prefs = await SharedPreferences.getInstance();
    if (await currentScope() != scope) throw StateError('主账号已变化');
    await prefs.setString(_sessionScopeKey, scope);
  }

  Future<bool> isCurrentSessionBound() async {
    final scope = await currentScope();
    if (scope == null) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_sessionScopeKey) == scope;
  }
}
