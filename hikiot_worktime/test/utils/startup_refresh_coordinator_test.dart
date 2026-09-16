import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/startup_refresh_coordinator.dart';

void main() {
  group('StartupRefreshCoordinator', () {
    test('已处理过期提示但会话未就绪时，不再继续刷新并重复弹窗', () async {
      final events = <String>[];

      await StartupRefreshCoordinator.run(
        initializeSession: () async => events.add('expired-dialog-dismissed'),
        refreshDaily: () async => events.add('refresh-daily'),
        refreshMonthly: () async => events.add('refresh-monthly'),
        isMounted: () => true,
        isSessionReady: () => false,
      );

      expect(events, ['expired-dialog-dismissed']);
    });

    test('会话初始化成功后继续完整启动刷新', () async {
      final events = <String>[];
      var ready = false;

      await StartupRefreshCoordinator.run(
        initializeSession: () async {
          ready = true;
          events.add('initialize-session');
        },
        refreshDaily: () async => events.add('refresh-daily'),
        refreshMonthly: () async => events.add('refresh-monthly'),
        isMounted: () => true,
        isSessionReady: () => ready,
      );

      expect(events, [
        'initialize-session',
        'refresh-daily',
        'refresh-monthly',
      ]);
    });

    test('refreshes daily data only after session initialization', () async {
      final events = <String>[];

      await StartupRefreshCoordinator.run(
        initializeSession: () async {
          events.add('initialize-session');
        },
        refreshDaily: () async {
          events.add('refresh-daily');
        },
        refreshMonthly: () async {
          events.add('refresh-monthly');
        },
        isMounted: () => true,
      );

      expect(events, [
        'initialize-session',
        'refresh-daily',
        'refresh-monthly',
      ]);
    });

    test('does not refresh child pages after the owner is unmounted', () async {
      final events = <String>[];
      var mounted = true;

      await StartupRefreshCoordinator.run(
        initializeSession: () async {
          events.add('initialize-session');
          mounted = false;
        },
        refreshDaily: () async {
          events.add('refresh-daily');
        },
        refreshMonthly: () async {
          events.add('refresh-monthly');
        },
        isMounted: () => mounted,
      );

      expect(events, ['initialize-session']);
    });
  });
}
