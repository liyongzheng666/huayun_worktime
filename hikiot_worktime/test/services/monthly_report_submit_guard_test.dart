import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/monthly_report_balance_service.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';

import '../helpers/monthly_report_balance_fixture.dart';

class _Controller implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Submit extends WorkLogSubmitService {
  _Submit(MonthlyReportBalanceService balance)
    : super(_Controller(), monthlyBalanceService: balance);
  int scripts = 0;
  @override
  Future<String?> runScript(String script, {bool logResult = true}) async {
    scripts++;
    return '{"ok":true,"objectId":"WORKLOG_test"}';
  }

  @override
  Future<double?> queryExistingHours(String dateStr) async => 10.4;
}

const _entry = WorkLogEntry(
  date: '2026-09-01',
  projectName: '测试',
  workType: '研发',
  stage: '无',
  activity: '无',
  title: '测试',
  content: '测试',
);

void main() {
  late MonthlyBalanceFixture fixture;
  late _Submit submit;
  late MonthlyReportSnapshot snapshot;
  setUp(() async {
    fixture = MonthlyBalanceFixture();
    await fixture.seed();
    snapshot = await fixture.service.load(fixture.now);
    submit = _Submit(fixture.service);
  });

  Future<WorkLogSubmitResult> send({
    String hours = '10.40',
    bool adopted = true,
  }) => submit.submit(
    entry: _entry,
    actWork: hours,
    constants: const {'projectId': 'PROJECT_test', 'auditor': 'USER_1'},
    monthlyBalance: adopted ? snapshot : null,
  );

  test('有效建议继续原提交流程，执行一次保存并回读实际工时', () async {
    expect((await send()).status, WorkLogSubmitStatus.submitted);
    expect(submit.scripts, 1);
  });
  test('别日工时改变后不发送任何保存脚本', () async {
    await fixture.storage.saveBossHoursForDate(
      '2026-09-02',
      10.5,
      refreshedAt: fixture.now,
    );
    expect((await send()).status, WorkLogSubmitStatus.deferred);
    expect(submit.scripts, 0);
  });
  test('建议与提交工时不一致时拦截，不能套用旧建议证明', () async {
    expect((await send(hours: '10.41')).status, WorkLogSubmitStatus.deferred);
    expect(submit.scripts, 0);
  });
  test('建议确认过期后拦截', () async {
    fixture.now = fixture.now.add(const Duration(minutes: 16));
    expect((await send()).status, WorkLogSubmitStatus.deferred);
    expect(submit.scripts, 0);
  });
  test('未采用月度建议的原手填流程仍可使用', () async {
    expect(
      (await send(hours: '10.42', adopted: false)).status,
      WorkLogSubmitStatus.submitted,
    );
    expect(submit.scripts, 1);
  });
}
