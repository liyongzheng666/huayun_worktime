import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/monthly_calendar_screen.dart';
import 'package:hikiot_worktime/screens/photo_preview_screen.dart';
import 'package:hikiot_worktime/services/hikiot_api_client.dart';
import 'package:hikiot_worktime/services/monthly_attendance_aggregator.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PhotoApi extends HikiotApiClient {
  int detailRequests = 0;
  bool legacyMonth = false;
  bool failDetail = false;
  Completer<Map<String, dynamic>?>? pendingDetail;
  @override
  Future<Map<String, dynamic>?> getAccountDetail() async => {
    'teamInfoList': [
      {'teamNo': 'team', 'teamName': '测试团队', 'personNo': 'person'},
    ],
  };
  @override
  Future<bool> changeTeam(String teamNo) async => true;
  @override
  Future<Map<String, dynamic>?> getMonthlyAttendance(
    String month,
    String personNo,
  ) async {
    final data = await MonthlyAttendanceAggregator(
      month: month,
      personNo: personNo,
      loadDailyAttendance: (date, _) async => response(date),
    ).aggregate();
    if (legacyMonth) {
      for (final row in data['dailyRecords'] as List) {
        row.remove('checkInPhotoUrl');
        row.remove('checkOutPhotoUrl');
      }
    }
    return data;
  }

  @override
  Future<Map<String, dynamic>?> getDailyAttendance(
    String date,
    String personNo,
  ) async {
    detailRequests++;
    if (pendingDetail != null) return pendingDetail!.future;
    if (failDetail) return null;
    return response(date);
  }

  Map<String, dynamic> response(String date) => {
    'dailyDetail': {
      'shiftId': 1,
      'shiftDetails': [
        {
          'clockInTime': '09:00',
          if (!date.endsWith('-02')) 'clockOffTime': '18:00',
          if (!date.endsWith('-03'))
            'remoteClockInInfo': {'photo': 'https://example.test/in.jpg'},
          if (date.endsWith('-01'))
            'remoteClockOffInfo': {'photo': 'https://example.test/out.jpg'},
        },
      ],
    },
  };
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlatformCapabilities.debugOverride =
        const PlatformCapabilitiesOverride.android();
    await HapticUtils.setMode(HapticMode.off);
  });
  tearDown(() => PlatformCapabilities.debugOverride = null);

  Future<void> openDay(WidgetTester tester, PhotoApi api, int day) async {
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MonthlyCalendarScreen(token: 'test', apiClient: api),
      ),
    );
    await tester.pumpAndSettle();
    final cell = find.descendant(
      of: find.byType(GridView),
      matching: find.text('$day'),
    );
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
  }

  testWidgets('月度真实聚合与合并后，日详情能打开上下班照片且不重复查询', (tester) async {
    final api = PhotoApi();
    await openDay(tester, api, 1);
    expect(find.text('上班照片'), findsOneWidget);
    expect(find.text('下班照片'), findsOneWidget);
    expect(api.detailRequests, 0);
    await tester.ensureVisible(find.text('上班照片'));
    await tester.tap(find.text('上班照片'));
    await tester.pumpAndSettle();
    final preview = tester.widget<PhotoPreviewScreen>(
      find.byType(PhotoPreviewScreen),
    );
    expect(preview.photoUrl, 'https://example.test/in.jpg');
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('保存图片'), findsOneWidget);
  });

  testWidgets('只有上班卡且工时为零时仍能查看照片，缺下班照片明确显示', (tester) async {
    final api = PhotoApi();
    await openDay(tester, api, 2);
    expect(find.text('上班照片'), findsOneWidget);
    expect(find.text('暂无下班照片'), findsOneWidget);
    expect(api.detailRequests, 0);
  });

  testWidgets('已确认无照片时明确显示暂无照片，不追加日查询', (tester) async {
    final api = PhotoApi();
    await openDay(tester, api, 3);
    expect(find.text('暂无上班照片'), findsOneWidget);
    expect(find.text('暂无下班照片'), findsOneWidget);
    expect(api.detailRequests, 0);
  });

  testWidgets('旧数据打开日详情零请求，点击照片才查一次，上下班及重开窗口复用', (tester) async {
    final api = PhotoApi()..legacyMonth = true;
    await openDay(tester, api, 1);
    expect(find.text('上班照片'), findsOneWidget);
    expect(api.detailRequests, 0);
    await tester.ensureVisible(find.text('出差'));
    await tester.tap(find.text('出差'));
    await tester.pumpAndSettle();
    expect(api.detailRequests, 0);
    await tester.ensureVisible(find.text('上班照片'));
    await tester.tap(find.text('上班照片'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoPreviewScreen), findsOneWidget);
    expect(api.detailRequests, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('下班照片'));
    await tester.tap(find.text('下班照片'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PhotoPreviewScreen>(find.byType(PhotoPreviewScreen))
          .photoUrl,
      'https://example.test/out.jpg',
    );
    expect(api.detailRequests, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    final cell = find.descendant(
      of: find.byType(GridView),
      matching: find.text('1'),
    );
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('上班照片'), findsOneWidget);
    expect(api.detailRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('照片补查失败显示重试，不能误报暂无照片', (tester) async {
    final api = PhotoApi()
      ..legacyMonth = true
      ..failDetail = true;
    await openDay(tester, api, 1);
    expect(api.detailRequests, 0);
    await tester.ensureVisible(find.text('上班照片'));
    await tester.tap(find.text('上班照片'));
    await tester.pumpAndSettle();
    expect(find.text('照片查询失败，请点击照片重试'), findsOneWidget);
    expect(find.text('暂无上班照片'), findsNothing);
    api.failDetail = false;
    await tester.ensureVisible(find.text('上班照片'));
    await tester.tap(find.text('上班照片'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoPreviewScreen), findsOneWidget);
    expect(api.detailRequests, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('补查尚未完成时关闭日详情，迟到响应不更新已销毁窗口', (tester) async {
    final api = PhotoApi()
      ..legacyMonth = true
      ..pendingDetail = Completer<Map<String, dynamic>?>();
    await openDay(tester, api, 1);
    expect(api.detailRequests, 0);
    await tester.ensureVisible(find.text('上班照片'));
    await tester.tap(find.text('上班照片'));
    await tester.pumpAndSettle();
    expect(find.text('查询上班…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    api.pendingDetail!.complete(api.response('2026-11-01'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(PhotoPreviewScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
