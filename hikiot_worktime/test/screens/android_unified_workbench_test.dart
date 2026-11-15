import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/storage_keys.dart';
import 'package:hikiot_worktime/core/theme/app_skin.dart';
import 'package:hikiot_worktime/screens/main_screen.dart';
import 'package:hikiot_worktime/screens/settings_screen.dart';
import 'package:hikiot_worktime/screens/theme_selection_screen.dart';
import 'package:hikiot_worktime/services/app_theme_controller.dart';
import 'package:hikiot_worktime/services/daily_attendance_repository.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:hikiot_worktime/widgets/ios_workbench.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends HikiotApiClient {
  @override
  Future<Map<String, dynamic>?> getAccountDetail() async => {
    'nickName': '测试用户',
    'teamInfoList': [
      {'teamNo': 'test-team', 'teamName': '测试团队', 'personNo': 'test-person'},
    ],
  };

  @override
  Future<bool> changeTeam(String teamNo) async => true;

  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async => {'dailyRecords': <dynamic>[]};

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async => null;
}

class _Attendance extends DailyAttendanceRepository {
  @override
  Future<DailyAttendanceLoadResult> load(
    DateTime date, {
    DateTime? workDate,
  }) async => const DailyAttendanceLoadResult(
    status: DailyAttendanceLoadStatus.loaded,
    teamNo: 'test-team',
    holidayPlan: {},
    dayData: {'type': '工作日', 'hours': 8.0},
    attendanceData: {
      'hours': 8.0,
      'checkInTime': '09:00',
      'checkOutTime': '18:00',
    },
    pinnedTarget: null,
    baseTarget: 120,
    minTarget: 100,
  );
}

void main() {
  final storage = StorageService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      StorageKeys.onboardingCompleted: true,
    });
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await HapticUtils.setMode(HapticMode.off);
    await storage.saveBossHours(DateHelper.formatMonth(DateTime.now()), {});
  });

  tearDown(() {
    PlatformCapabilities.debugOverride = null;
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await AppThemeController.shared.load();
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: AppThemeController.shared,
        builder: (context, _) => MaterialApp(
          theme: AppThemeController.shared.themeData,
          home: MainScreen(
            token: 'test-token',
            apiClient: _Api(),
            dailyRepository: _Attendance(),
            // 固定非月底时钟，只隔离月底弹窗，本测试验证真实主框架与统一界面。
            monthlyBalanceService: MonthlyReportBalanceService(
              clock: () => DateTime(2026, 9, 3, 19),
            ),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'Android统一工作台、导航和8主题可选并持久化，保留原后台能力',
    (tester) async {
      await open(tester);
      expect(find.byType(IosWorkbench), findsOneWidget);
      for (final label in ['今日', '月度', '日志', '我的']) {
        expect(find.text(label), findsOneWidget);
      }
      final context = tester.element(find.byType(IosWorkbench));
      expect(Theme.of(context).platform, TargetPlatform.android);
      expect(Theme.of(context).colorScheme.primary, AppSkin.grass.accent);
      expect(
        tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byKey(const ValueKey('workbench-system-bars')),
            )
            .value
            .statusBarIconBrightness,
        Brightness.dark,
      );
      expect(PlatformCapabilities.supportsExactBackgroundAlarm, isTrue);
      expect(PlatformCapabilities.needsVendorKeepAliveGuide, isTrue);
      await tester.tap(find.text('我的'));
      await flush(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('外观与主题'), findsOneWidget);
      await tester.tap(find.text('外观与主题'));
      await flush(tester);
      expect(find.byType(ThemeSelectionScreen), findsOneWidget);
      expect(AppSkin.all, hasLength(8));
      for (final skin in AppSkin.all) {
        expect(find.byKey(ValueKey('skin-${skin.id}')), findsOneWidget);
      }
      await tester.ensureVisible(find.byKey(const ValueKey('skin-graphite')));
      await tester.tap(find.byKey(const ValueKey('skin-graphite')));
      await flush(tester);
      expect(AppThemeController.shared.current, AppSkin.byId('graphite'));
      expect(await storage.loadAppSkinId(), 'graphite');
      expect(
        Theme.of(tester.element(find.byType(ThemeSelectionScreen))).brightness,
        Brightness.dark,
      );
      await tester.pageBack();
      await flush(tester);
      final bars = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byKey(const ValueKey('workbench-system-bars')),
          )
          .value;
      expect(bars.statusBarIconBrightness, Brightness.light);
      expect(bars.systemNavigationBarIconBrightness, Brightness.light);
      expect(
        Theme.of(tester.element(find.byType(MainScreen))).platform,
        TargetPlatform.android,
      );
      await close(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
