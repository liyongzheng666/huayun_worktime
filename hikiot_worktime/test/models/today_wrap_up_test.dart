import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/today_wrap_up.dart';

void main() {
  final now = DateTime(2026, 9, 15, 19);
  final punches = <String, dynamic>{
    'checkInTime': '08:30',
    'checkOutTime': '18:30',
  };

  TodayWrapUpSummary summary({
    TodayBossStatus status = TodayBossStatus.unknown,
    double? hours,
    bool hasEntry = true,
    String dayType = '工作日',
    Map<String, dynamic>? attendance,
    DateTime? checkedAt,
    DateTime? current,
    bool loading = false,
    bool failed = false,
  }) => TodayWrapUpSummary.compose(
    date: now,
    data: TodayWrapUpData(
      date: now,
      hasEntry: hasEntry,
      bossStatus: status,
      bossHours: hours,
      checkedAt: checkedAt ?? now,
    ),
    attendanceData: attendance ?? punches,
    dayType: dayType,
    attendanceLoading: loading,
    attendanceFailed: failed,
    effectiveHours: 9.129,
    now: current ?? now,
  );

  test('未知不能当成未提交，也不能从 CSV 推断已提交', () {
    final value = summary();
    expect(value.csv.status, TodayWrapUpItemStatus.complete);
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
    expect(value.submission.label, '日志提交状态待确认');
    expect(value.primaryAction, TodayWrapUpAction.refresh);
  });

  test('实时 0 工时才显示尚未提交并提供检查入口', () {
    final value = summary(status: TodayBossStatus.unsubmitted, hours: 0);
    expect(value.submission.label, '今天尚未提交日志');
    expect(value.primaryAction, TodayWrapUpAction.reviewLog);
  });

  test('正数表示已提交，文案不宣告考勤合规或可以下班', () {
    final value = summary(status: TodayBossStatus.submitted, hours: 9.129);
    expect(value.submission.detail, contains('9.12'));
    expect(value.attendance.detail, contains('9.12'));
    expect(value.primaryAction, TodayWrapUpAction.viewLog);
    expect(value.subtitle, contains('仍请按实际安排核对'));
  });

  test('缺 CSV 时直接提供素材导入入口', () {
    final value = summary(
      status: TodayBossStatus.unsubmitted,
      hours: 0,
      hasEntry: false,
    );
    expect(value.csv.status, TodayWrapUpItemStatus.pending);
    expect(value.primaryAction, TodayWrapUpAction.importCsv);
  });

  test('只有上班卡不会把考勤判成完成', () {
    final value = summary(
      attendance: {'checkInTime': '08:30', 'checkOutTime': '-'},
    );
    expect(value.attendance.label, '已查到上班记录');
    expect(value.attendance.status, TodayWrapUpItemStatus.pending);
  });

  test('过期的已提交状态变未知', () {
    final value = summary(
      status: TodayBossStatus.submitted,
      hours: 8,
      checkedAt: now.subtract(const Duration(minutes: 15)),
    );
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
    expect(value.primaryAction, TodayWrapUpAction.refresh);
  });

  test('未来查询时间也不能视为新鲜数据', () {
    final value = summary(
      status: TodayBossStatus.submitted,
      hours: 8,
      checkedAt: now.add(const Duration(minutes: 1)),
    );
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
  });

  test('跨天打卡提示核对，不夸完成', () {
    final value = summary(
      status: TodayBossStatus.submitted,
      hours: 8,
      attendance: {...punches, 'hasCrossDayPunch': true},
    );
    expect(value.attendance.status, TodayWrapUpItemStatus.pending);
    expect(value.title, contains('跨天'));
    expect(value.primaryAction, TodayWrapUpAction.checkAttendance);
  });

  test('自然日期已变化，即使刚查询过也不能当作今日完成', () {
    final value = summary(
      status: TodayBossStatus.submitted,
      hours: 8,
      current: DateTime(2026, 9, 16),
    );
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
    expect(value.title, contains('日期'));
    expect(value.primaryAction, TodayWrapUpAction.checkAttendance);
  });

  for (final type in ['非工作日', '休息', '节假日', '请假']) {
    test('$type 不催促为卡片完成导入日志或补卡', () {
      final value = TodayWrapUpSummary.compose(
        date: now,
        data: TodayWrapUpData(
          date: now,
          bossStatus: TodayBossStatus.unsubmitted,
          bossHours: 0,
          checkedAt: now,
        ),
        attendanceData: {},
        dayType: type,
        effectiveHours: 0,
        now: now,
      );
      expect(value.attendance.status, TodayWrapUpItemStatus.neutral);
      expect(value.csv.status, TodayWrapUpItemStatus.neutral);
      expect(value.primaryAction, TodayWrapUpAction.checkAttendance);
    });
  }

  test('出差不提示缺卡，但仍允许检查日志', () {
    final value = summary(
      status: TodayBossStatus.unsubmitted,
      hours: 0,
      dayType: '出差',
      attendance: {},
    );
    expect(value.attendance.status, TodayWrapUpItemStatus.neutral);
    expect(value.attendance.detail, contains('出差安排'));
    expect(value.primaryAction, TodayWrapUpAction.reviewLog);
  });

  test('考勤正在刷新或者失败时旧记录不能冒充本次确认', () {
    expect(
      summary(loading: true).attendance.status,
      TodayWrapUpItemStatus.unknown,
    );
    expect(
      summary(failed: true).attendance.status,
      TodayWrapUpItemStatus.unknown,
    );
  });

  test('null 考勤不是零工时或已确认无卡', () {
    final value = TodayWrapUpSummary.compose(
      date: now,
      data: TodayWrapUpData(date: now),
      now: now,
    );
    expect(value.attendance.status, TodayWrapUpItemStatus.unknown);
  });

  test('未登录给登录入口，已提交缓存带时间并明确上次', () {
    final value = TodayWrapUpSummary.compose(
      date: now,
      data: TodayWrapUpData(
        date: now,
        bossStatus: TodayBossStatus.noSession,
        cachedBossHours: 8,
        cachedAt: now.subtract(const Duration(hours: 2)),
      ),
      now: now,
    );
    expect(value.primaryAction, TodayWrapUpAction.loginBoss);
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
    expect(value.submission.detail, contains('上次记录已填'));
    expect(value.submission.detail, contains('月度缓存同步于 2026-09-15 17:00'));
  });

  test('错误日期的数据不污染今天素材和提交状态', () {
    final value = TodayWrapUpSummary.compose(
      date: now,
      data: TodayWrapUpData(
        date: now.subtract(const Duration(days: 1)),
        hasEntry: true,
        bossStatus: TodayBossStatus.submitted,
        bossHours: 8,
        checkedAt: now,
      ),
      now: now,
    );
    expect(value.csv.status, TodayWrapUpItemStatus.pending);
    expect(value.submission.status, TodayWrapUpItemStatus.unknown);
    expect(value.primaryAction, TodayWrapUpAction.checkAttendance);
  });

  for (final badHours in [double.nan, double.infinity, -1.0]) {
    test('无效工时 $badHours 保持未知', () {
      expect(
        summary(
          status: TodayBossStatus.submitted,
          hours: badHours,
        ).submission.status,
        TodayWrapUpItemStatus.unknown,
      );
    });
  }
}
