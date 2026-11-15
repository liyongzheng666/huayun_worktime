import 'package:flutter/material.dart';

import '../widgets/boss_login_dialog.dart';
import 'boss_credentials_service.dart';
import 'boss_session_runner.dart';
import 'storage_service.dart';

/// 统一手工登录、系统安全存储及会话失效恢复，不重放任何业务写入。
class BossLoginCoordinator {
  BossLoginCoordinator._();

  static Future<bool> prompt({
    required BuildContext context,
    required Future<void> Function() openWeb,
    StorageService? storage,
    BossCredentialsService? credentialsService,
    bool forceManual = false,
    String successMessage = 'BOSS 登录成功，正在继续操作…',
  }) async {
    final store = storage ?? StorageService();
    final credentials =
        credentialsService ?? BossCredentialsService(storage: store);
    final scope = await credentials.currentScope();
    if (!context.mounted) return false;
    if (scope == null) {
      _notify(context, '主账号身份尚未确认，请等待资料加载完成后再登录 BOSS');
      return false;
    }
    final saved = await credentials.loadForCurrentScope();
    if (!forceManual &&
        (saved?.automaticLoginEnabled == true ||
            await credentials.isCurrentSessionBound())) {
      final restored = await BossSessionRunner.restoreRememberedSession(
        credentialsService: credentials,
      );
      if (await credentials.currentScope() != scope || !context.mounted) {
        return false;
      }
      if (restored) {
        _notify(context, successMessage);
        return true;
      }
    }
    final initialUserName =
        saved?.userName ?? await store.loadBossLoginUserName();
    if (await credentials.currentScope() != scope || !context.mounted) {
      return false;
    }
    final request = await BossLoginDialog.show(
      context: context,
      initialUserName: initialUserName,
      hasRememberedPassword: saved != null,
    );
    if (request == null ||
        await credentials.currentScope() != scope ||
        !context.mounted) {
      return false;
    }
    if (request.forgetCredentials) {
      final bound = await credentials.isCurrentSessionBound();
      try {
        await credentials.forgetCurrentScope();
        if (bound) await credentials.bindCurrentSession(expectedScope: scope);
        if (context.mounted) _notify(context, '已清除记住的 BOSS 密码，自动登录已关闭');
      } catch (_) {
        if (context.mounted) _notify(context, '清除密码记忆未完成，请重试');
      }
      return false;
    }
    if (request.openWeb) {
      await openWeb();
      if (await credentials.currentScope() != scope || !context.mounted) {
        return false;
      }
      return BossSessionRunner.bindWebSession(
        credentialsService: credentials,
        expectedScope: scope,
      );
    }
    if (!request.rememberPassword) {
      try {
        await credentials.forgetCurrentScope();
      } catch (_) {
        /* 停用标记已先写入；手工认证仍可继续。 */
      }
    }
    if (await credentials.currentScope() != scope || !context.mounted) {
      return false;
    }
    _notify(context, '正在后台登录 BOSS…');
    final result = await BossSessionRunner.login(
      userName: request.userName,
      password: request.password,
      credentialsService: credentials,
      expectedScope: scope,
    );
    if (await credentials.currentScope() != scope || !context.mounted) {
      return false;
    }
    if (!result.ok) {
      _notify(context, result.message ?? 'BOSS 登录失败，请核对账号密码');
      return false;
    }
    await store.saveBossLoginUserName(request.userName);
    if (await credentials.currentScope() != scope || !context.mounted) {
      return false;
    }
    if (request.rememberPassword && result.passwordAuthenticated) {
      try {
        await credentials.rememberForCurrentScope(
          userName: request.userName,
          password: request.password,
          expectedScope: scope,
        );
      } catch (_) {
        if (context.mounted) _notify(context, 'BOSS 已登录，但本机未能记住密码；下次可重新设置');
        return true;
      }
    } else if (request.rememberPassword && !result.passwordAuthenticated) {
      _notify(context, '已沿用当前 BOSS 会话。本次输入的密码未经过认证，未保存新密码');
      return true;
    }
    if (context.mounted) _notify(context, successMessage);
    return true;
  }

  static void _notify(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }
}
