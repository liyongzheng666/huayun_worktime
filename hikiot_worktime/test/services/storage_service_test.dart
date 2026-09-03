import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/constants.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/utils/work_time_calculator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('StorageService 已提交日志 ID', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('按日期保存，多个日期互不覆盖', () async {
      final storage = StorageService();
      await storage.saveWorkLogObjectId('2026-09-02', 'WORKLOG_a');
      await storage.saveWorkLogObjectId('2026-09-03', 'WORKLOG_b');

      expect(await storage.loadWorkLogObjectId('2026-09-02'), 'WORKLOG_a');
      expect(await storage.loadWorkLogObjectId('2026-09-03'), 'WORKLOG_b');
    });

    test('非法 ID 不落盘，移除后不再提供编辑入口', () async {
      final storage = StorageService();
      await storage.saveWorkLogObjectId('2026-09-03', 'PROJECT_wrong');
      expect(await storage.loadWorkLogObjectId('2026-09-03'), isNull);

      await storage.saveWorkLogObjectId('2026-09-03', 'WORKLOG_ok');
      await storage.removeWorkLogObjectId('2026-09-03');
      expect(await storage.loadWorkLogObjectId('2026-09-03'), isNull);
    });

    test('更新单日 BOSS 工时时保留同月其他日期', () async {
      final storage = StorageService();
      await storage.saveBossHours('2026-09', {'2026-09-01': 8});
      await storage.saveBossHoursForDate('2026-09-03', 9.5);

      expect(await storage.loadBossHours('2026-09'), {
        '2026-09-01': 8,
        '2026-09-03': 9.5,
      });
    });
  });

  group('StorageService BOSS 提交配置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('保存与读回三个业务标识', () async {
      final storage = StorageService();

      await storage.saveBossConstants({
        'projectId': 'PROJECT_aaa',
        'projectCode': 'PROJECT_bbb',
        'auditor': ';USERINFO_ccc',
      });

      final loaded = await storage.loadBossConstants();
      expect(loaded['projectId'], 'PROJECT_aaa');
      expect(loaded['projectCode'], 'PROJECT_bbb');
      expect(loaded['auditor'], ';USERINFO_ccc');
    });

    test('清除后回到「从未配置」状态，好让后台自动学习重新介入', () async {
      // 保存按钮要求项目 ID 非空，光把输入框清空是存不下去的，
      // 因此必须有一条独立的清除路径，否则没法回到未配置状态。
      final storage = StorageService();
      await storage.saveBossConstants({
        'projectId': 'PROJECT_aaa',
        'projectCode': 'PROJECT_bbb',
        'auditor': ';USERINFO_ccc',
      });

      await storage.clearBossConstants();

      expect(await storage.loadBossConstants(), isEmpty);
    });
  });

  group('StorageService session context', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves and loads team and person numbers together', () async {
      final storage = StorageService();

      await storage.saveTeamContext(teamNo: 'team-1', personNo: 'person-1');

      expect(await storage.loadTeamNo(), 'team-1');
      expect(await storage.loadPersonNo(), 'person-1');
    });

    test('does not overwrite person number when it is absent', () async {
      final storage = StorageService();
      await storage.saveTeamContext(teamNo: 'team-1', personNo: 'person-1');

      await storage.saveTeamContext(teamNo: 'team-2');

      expect(await storage.loadTeamNo(), 'team-2');
      expect(await storage.loadPersonNo(), 'person-1');
    });
  });

  group('StorageService settings schema', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      WorkTimeCalculator.lunchStartMinutes = 12 * 60;
      WorkTimeCalculator.lunchEndMinutes = 13 * 60;
      DateHelper.crossDayMinutes = AppConstants.defaultCrossDayMinutes;
    });

    test(
      'migrates legacy settings into canonical and compatibility keys',
      () async {
        SharedPreferences.setMockInitialValues({
          StorageKeys.settings: jsonEncode({
            'targets': [100, 120],
            'lunch_break': {'start': '11:45', 'end': '12:30'},
            'day_change_hour': 3,
            'display_name': 'Alice',
          }),
        });
        final storage = StorageService();

        final settings = await storage.loadSettings();

        expect(settings[StorageKeys.lunchStartTime], '11:45');
        expect(settings[StorageKeys.lunchEndTime], '12:30');
        expect(settings[StorageKeys.crossDayMinutes], 180);
        expect(settings['lunchStartTime'], '11:45');
        expect(settings['lunchEndTime'], '12:30');
        expect(settings['day_change_hour'], 3);
        expect((settings['lunch_break'] as Map)['start'], '11:45');
        expect((settings['lunch_break'] as Map)['end'], '12:30');

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(StorageKeys.lunchStartTime), '11:45');
        expect(prefs.getString(StorageKeys.lunchEndTime), '12:30');
        expect(prefs.getInt(StorageKeys.crossDayMinutes), 180);
      },
    );

    test(
      'saves settings to JSON and scalar keys used by startup tools',
      () async {
        final storage = StorageService();

        await storage.saveSettings({
          'lunchStartTime': '10:30',
          'lunchEndTime': '11:15',
          StorageKeys.crossDayMinutes: 150,
        });

        final settings = await storage.loadSettings();
        final prefs = await SharedPreferences.getInstance();

        expect(settings[StorageKeys.lunchStartTime], '10:30');
        expect(settings[StorageKeys.lunchEndTime], '11:15');
        expect(settings[StorageKeys.crossDayMinutes], 150);
        expect(settings['lunchStartTime'], '10:30');
        expect(settings['lunchEndTime'], '11:15');
        expect(prefs.getString(StorageKeys.lunchStartTime), '10:30');
        expect(prefs.getString(StorageKeys.lunchEndTime), '11:15');
        expect(prefs.getInt(StorageKeys.crossDayMinutes), 150);
      },
    );

    test('startup calculators read migrated legacy settings', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.settings: jsonEncode({
          'lunch_break': {'start': '11:20', 'end': '12:10'},
          'day_change_hour': 2,
        }),
      });

      await WorkTimeCalculator.reload();
      await DateHelper.reload();

      expect(WorkTimeCalculator.lunchStartMinutes, 11 * 60 + 20);
      expect(WorkTimeCalculator.lunchEndMinutes, 12 * 60 + 10);
      expect(DateHelper.crossDayMinutes, 2 * 60);
    });
  });

  group('StorageService reminder settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('migrates legacy alarm keys to canonical reminder keys', () async {
      SharedPreferences.setMockInitialValues({
        'morning_alarm_enabled': true,
        'morning_alarm_hour': 7,
        'morning_alarm_minute': 45,
        'evening_alarm_enabled': true,
        'evening_alarm_hour': 20,
        'evening_alarm_minute': 30,
      });
      final storage = StorageService();

      final settings = await storage.loadReminderSettings();

      expect(settings.morningEnabled, isTrue);
      expect(settings.morningHour, 7);
      expect(settings.morningMinute, 45);
      expect(settings.eveningEnabled, isTrue);
      expect(settings.eveningHour, 20);
      expect(settings.eveningMinute, 30);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(StorageKeys.morningReminderEnabled), isTrue);
      expect(prefs.getString(StorageKeys.morningReminderTime), '07:45');
      expect(prefs.getBool(StorageKeys.eveningReminderEnabled), isTrue);
      expect(prefs.getString(StorageKeys.eveningReminderTime), '20:30');
    });

    test('saves canonical and legacy reminder keys together', () async {
      final storage = StorageService();

      await storage.saveMorningReminder(enabled: true, hour: 8, minute: 50);
      await storage.saveEveningReminder(enabled: false, hour: 19, minute: 40);

      final settings = await storage.loadReminderSettings();
      final prefs = await SharedPreferences.getInstance();

      expect(settings.morningEnabled, isTrue);
      expect(settings.morningHour, 8);
      expect(settings.morningMinute, 50);
      expect(settings.eveningEnabled, isFalse);
      expect(settings.eveningHour, 19);
      expect(settings.eveningMinute, 40);
      expect(prefs.getString(StorageKeys.morningReminderTime), '08:50');
      expect(prefs.getInt('morning_alarm_hour'), 8);
      expect(prefs.getInt('morning_alarm_minute'), 50);
      expect(prefs.getString(StorageKeys.eveningReminderTime), '19:40');
      expect(prefs.getInt('evening_alarm_hour'), 19);
      expect(prefs.getInt('evening_alarm_minute'), 40);
    });
  });

  group('StorageService UI and session flags', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('normalizes token when saving and loading', () async {
      final storage = StorageService();

      await storage.saveToken('  token-1  ');

      expect(await storage.loadToken(), 'token-1');

      await storage.saveToken('   ');

      expect(await storage.loadToken(), isNull);
    });

    test('migrates legacy blank token to logged-out state', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.token: '   '});
      final storage = StorageService();

      expect(await storage.loadToken(), isNull);
    });

    test(
      'reads and writes onboarding completion through canonical key',
      () async {
        final storage = StorageService();

        expect(await storage.loadOnboardingCompleted(), isFalse);

        await storage.saveOnboardingCompleted(true);

        expect(await storage.loadOnboardingCompleted(), isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(StorageKeys.onboardingCompleted), isTrue);
      },
    );

    test('migrates legacy disclaimer flag to canonical key', () async {
      SharedPreferences.setMockInitialValues({'disclaimer_shown': true});
      final storage = StorageService();

      expect(await storage.loadDisclaimerAccepted(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(StorageKeys.disclaimerAccepted), isTrue);
      expect(prefs.getBool('disclaimer_shown'), isTrue);
    });

    test('saves developer and target range settings through storage', () async {
      final storage = StorageService();

      await storage.saveExtendedTargetRange(true);
      await storage.saveDebugToolsEnabled(true);

      expect(await storage.loadExtendedTargetRange(), isTrue);
      expect(await storage.loadDebugToolsEnabled(), isTrue);
    });

    test(
      'saves team display info while keeping legacy current team keys',
      () async {
        final storage = StorageService();

        await storage.saveTeamContext(
          teamNo: 'team-1',
          personNo: 'person-1',
          teamName: '研发团队',
        );

        expect(await storage.loadTeamNo(), 'team-1');
        expect(await storage.loadPersonNo(), 'person-1');
        expect(await storage.loadTeamName(), '研发团队');

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('current_team_no'), 'team-1');
        expect(prefs.getString('current_team_name'), '研发团队');
      },
    );

    test('loads team name from legacy current team key', () async {
      SharedPreferences.setMockInitialValues({'current_team_name': '旧团队'});
      final storage = StorageService();

      expect(await storage.loadTeamName(), '旧团队');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StorageKeys.teamName), '旧团队');
    });

    test('saves and loads haptic mode index through canonical key', () async {
      final storage = StorageService();

      expect(await storage.loadHapticModeIndex(), 0);

      await storage.saveHapticModeIndex(2);

      expect(await storage.loadHapticModeIndex(), 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(StorageKeys.hapticMode), 2);
    });
  });
}
