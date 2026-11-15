import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/models/boss_report_status.dart';

void main() {
  test('确认零合计表示未填报，不拼接已填零小时', () {
    const status = BossReportStatus(hours: 0, confirmed: true);
    expect(status.state, BossReportState.unreported);
    expect(status.statusText, '未填报');
    expect(status.hasPositiveHours, isFalse);
  });
  test('已有记录线索与零合计冲突时提示核对，不擅自断言没记录', () {
    const status = BossReportStatus(
      hours: 0,
      confirmed: true,
      hasKnownRecord: true,
    );
    expect(status.state, BossReportState.recordNeedsReview);
    expect(status.statusText, '已有日报记录，工时待核对');
  });
  test('没有当前证明不能把未知或旧零当作未填', () {
    for (final hours in <double?>[null, 0, 10.2]) {
      final status = BossReportStatus(hours: hours, confirmed: false);
      expect(status.state, BossReportState.unknown);
      expect(status.statusText, '待确认');
    }
  });
  test('已确认正数保留原金额，缺失和非法金额保持未知', () {
    const filled = BossReportStatus(hours: 10.2, confirmed: true);
    expect(filled.state, BossReportState.reported);
    expect(filled.hours, 10.2);
    for (final hours in <double?>[null, -1, double.nan, double.infinity]) {
      expect(
        BossReportStatus(hours: hours, confirmed: true).state,
        BossReportState.unknown,
      );
    }
  });
}
