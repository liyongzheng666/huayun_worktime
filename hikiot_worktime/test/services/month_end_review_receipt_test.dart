import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StorageService storage;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });
  test('核对状态按人员团队和月份隔离，恢复同一身份可回读', () async {
    await storage.saveTeamContext(teamNo: 'team', personNo: 'one');
    await storage.saveMonthReportReview('2026-11', 'summary');
    expect(await storage.loadMonthReportReview('2026-11'), 'summary');
    expect(await storage.loadMonthReportReview('2026-12'), isNull);
    await storage.saveTeamContext(teamNo: 'team', personNo: 'two');
    expect(await storage.loadMonthReportReview('2026-11'), isNull);
    await storage.saveTeamContext(teamNo: 'other', personNo: 'one');
    expect(await storage.loadMonthReportReview('2026-11'), isNull);
    await storage.saveTeamContext(teamNo: 'team', personNo: 'one');
    expect(await storage.loadMonthReportReview('2026-11'), 'summary');
  });
  test('身份不完整不保存跨会话核对标记', () async {
    await storage.saveMonthReportReview('2026-11', 'summary');
    expect(await storage.loadMonthReportReview('2026-11'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((k) => k.startsWith('month_report_review_')),
      isEmpty,
    );
  });
}
