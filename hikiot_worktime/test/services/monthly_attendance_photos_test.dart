import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/monthly_attendance_repository.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const date = '2026-11-02';
  final storage = StorageService();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> response({String? photo = 'in.jpg'}) => {
    'dailyDetail': {
      'shiftDetails': [
        {
          'clockInTime': '09:00',
          'clockOffTime': '18:00',
          'remoteClockInInfo': {'photo': photo},
          'remoteClockOffInfo': {'photo': 'out.jpg'},
        },
      ],
    },
  };

  for (final photo in ['in.jpg', null]) {
    test('并发点击只查一次，补查结果持久复用且保留期间修改的工时：$photo', () async {
      await storage.saveMonthlyData('team', '2026-11', {
        date: {'hours': 8.0, 'isManual': false},
      });
      await storage.saveMonthlyHoursCalculationVersion('team', '2026-11');
      final pending = Completer<Map<String, dynamic>?>();
      var requests = 0;
      final repository = MonthlyAttendanceRepository(
        loadMonthlyAttendance: (_, _) async => throw StateError('禁止整月重查'),
        loadDailyAttendance: (_, _) {
          requests++;
          return pending.future;
        },
      );
      await repository.loadMonth(
        teamNo: 'team',
        personNo: 'person',
        selectedMonth: DateTime(2026, 11),
      );
      final first = repository.loadDayPhotos(
        teamNo: 'team',
        personNo: 'person',
        date: date,
      );
      final second = repository.loadDayPhotos(
        teamNo: 'team',
        personNo: 'person',
        date: date,
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      await storage.saveMonthlyData('team', '2026-11', {
        date: {'hours': 7.25, 'isManual': true, 'type': '自定义'},
      });
      pending.complete(response(photo: photo));
      final results = await Future.wait([first, second]);
      expect(results.first.checkInPhotoUrl, photo);
      final saved = (await storage.loadMonthlyData('team', '2026-11'))![date]!;
      expect(saved['hours'], 7.25);
      expect(saved['isManual'], true);
      expect(saved['type'], '自定义');
      expect(saved.containsKey('checkInPhotoUrl'), true);
      expect(saved['checkInPhotoUrl'], photo);
      expect(saved['checkOutPhotoUrl'], 'out.jpg');
      final restarted = MonthlyAttendanceRepository(
        loadMonthlyAttendance: (_, _) async => throw StateError('禁止整月重查'),
        loadDailyAttendance: (_, _) async => throw StateError('禁止重复日查询'),
      );
      expect(
        (await restarted.loadDayPhotos(
          teamNo: 'team',
          personNo: 'person',
          date: date,
        )).checkInPhotoUrl,
        photo,
      );
      expect(
        (await repository.loadDayPhotos(
          teamNo: 'team',
          personNo: 'person',
          date: date,
        )).checkInPhotoUrl,
        photo,
      );
      expect(requests, 1);
    });
  }

  test('打卡不变、仅照片更新时保留快速同步停止边界并刷新缓存', () async {
    var requests = 0;
    final repository = MonthlyAttendanceRepository(
      loadMonthlyAttendance: (_, _) async => null,
      loadDailyAttendance: (_, _) async {
        requests++;
        return response();
      },
    );
    final result = await repository.smartQuickUpdate(
      teamNo: 'team',
      personNo: 'person',
      selectedMonth: DateTime(2026, 11),
      now: DateTime(2026, 11, 2, 19),
      currentData: {
        date: {
          'checkIn': '09:00',
          'checkOut': '18:00',
          'hours': 8.0,
          'type': '工作日',
          'dataSourceStatus': 'apiConfirmed',
          'checkInPhotoUrl': 'old.jpg',
          'checkOutPhotoUrl': 'old-out.jpg',
        },
      },
    );
    expect(requests, 1);
    expect(result.updatedCount, 1);
    expect(result.monthlyData[date]!['checkInPhotoUrl'], 'in.jpg');
    expect(result.monthlyData[date]!['checkOutPhotoUrl'], 'out.jpg');
  });

  test('已有地址正常打开零日查询，仅明确失效重试强制查一次后继续复用', () async {
    await storage.saveMonthlyData('team', '2026-11', {
      date: {
        'checkInPhotoUrl': 'old-in.jpg',
        'checkOutPhotoUrl': 'old-out.jpg',
      },
    });
    var requests = 0;
    final repository = MonthlyAttendanceRepository(
      loadMonthlyAttendance: (_, _) async => throw StateError('禁止整月重查'),
      loadDailyAttendance: (_, _) async {
        requests++;
        return response();
      },
    );
    await repository.loadDayPhotos(
      teamNo: 'team',
      personNo: 'person',
      date: date,
    );
    expect(requests, 0);
    final fresh = await repository.loadDayPhotos(
      teamNo: 'team',
      personNo: 'person',
      date: date,
      forceRefresh: true,
    );
    expect(fresh.checkOutPhotoUrl, 'out.jpg');
    expect(requests, 1);
    await repository.loadDayPhotos(
      teamNo: 'team',
      personNo: 'person',
      date: date,
    );
    expect(requests, 1);
  });
}
