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

    await refreshDaily();
    if (!isMounted()) return;

    await refreshMonthly();
  }
}
