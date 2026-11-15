typedef AsyncStep = Future<void> Function();
typedef MountedCheck = bool Function();

class StartupRefreshCoordinator {
  StartupRefreshCoordinator._();

  static Future<void> run({
    required AsyncStep initializeSession,
    required AsyncStep refreshDaily,
    required AsyncStep refreshMonthly,
    required MountedCheck isMounted,
    bool Function()? isSessionReady,
  }) async {
    await initializeSession();
    if (!isMounted() || (isSessionReady != null && !isSessionReady())) return;

    // 身份就绪后两页独立加载；今日无需等待整月，同会话请求可合并在途读取。
    await Future.wait([refreshDaily(), refreshMonthly()]);
  }
}
