import 'package:flutter/material.dart';

import '../widgets/boss_login_dialog.dart';
import 'boss_session_runner.dart';
import 'storage_service.dart';

/// BOSS 原生登录面板与隐藏 WebView 登录的统一编排。
///
/// 提交、编辑和月度同步都必须走这里；各页面自己复制一份最容易出现某个入口
/// 仍然跳网页，或某处误把密码落盘。密码只在本方法栈上存活。
class BossLoginCoordinator {
  BossLoginCoordinator._();

  static Future<bool> prompt({
    required BuildContext context,
    required Future<void> Function() openWeb,
    StorageService? storage,
    String successMessage = 'BOSS 登录成功，正在继续操作…',
  }) async {
    final store = storage ?? StorageService();
    final initialUserName = await store.loadBossLoginUserName();
    if (!context.mounted) return false;

    final request = await BossLoginDialog.show(
      context: context,
      initialUserName: initialUserName,
    );
    if (request == null || !context.mounted) return false;
    if (request.openWeb) {
      await openWeb();
      return false;
    }

    _notify(context, '正在后台登录 BOSS…');
    final result = await BossSessionRunner.login(
      userName: request.userName,
      password: request.password,
    );
    if (!context.mounted) return false;
    if (!result.ok) {
      _notify(context, result.message ?? 'BOSS 登录失败，请核对账号密码');
      return false;
    }

    await store.saveBossLoginUserName(request.userName);
    if (!context.mounted) return false;
    _notify(context, successMessage);
    return true;
  }

  static void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }
}
