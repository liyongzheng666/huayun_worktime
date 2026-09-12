import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_submit_service.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 测试只替换网页响应，保留提交编排、按日期复读和真实缓存写入。
class _UnusedController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SubmitService extends WorkLogSubmitService {
  _SubmitService({required this.submitReply, required this.query})
    : super(_UnusedController());

  final String submitReply;
  final Future<double?> Function(String date) query;
  final queriedDates = <String>[];
  int submitCalls = 0;

  @override
  Future<String?> runScript(String script, {bool logResult = true}) async {
    submitCalls++;
    return submitReply;
  }

  @override
  Future<double?> queryExistingHours(String dateStr) {
    queriedDates.add(dateStr);
    return query(dateStr);
  }
}

const _entry = WorkLogEntry(
  date: '2026-09-10',
  projectName: '测试项目',
  workType: '研发',
  stage: '无',
  activity: '无',
  title: '测试日志',
  content: '完成测试',
);

Future<WorkLogSubmitResult> _submit(_SubmitService service) => service.submit(
  entry: _entry,
  actWork: '8.00',
  constants: const {'projectId': 'PROJECT_1', 'auditor': 'USER_1'},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('确认提交后复读日志实际日期的合计，不使用提交输入或覆盖同月其他日期', () async {
    final storage = StorageService();
    await storage.saveBossHoursForDate('2026-09-09', 4.5);
    final service = _SubmitService(
      submitReply: '{"ok":true,"objectId":"WORKLOG_1"}',
      query: (_) async => 7.25,
    );

    final result = await _submit(service);

    expect(result.status, WorkLogSubmitStatus.submitted);
    expect(service.queriedDates, ['2026-09-10']);
    expect(service.submitCalls, 1);
    expect(await storage.loadWorkLogObjectId(_entry.date), 'WORKLOG_1');
    expect(await storage.loadBossHours('2026-09'), {
      '2026-09-09': 4.5,
      '2026-09-10': 7.25,
    });
  });

  test('该日已提交也复读服务端合计，更新去重时拿到的旧值', () async {
    final service = _SubmitService(
      submitReply: '{"alreadySubmitted":true,"existingHours":6.5}',
      query: (_) async => 7.25,
    );

    final result = await _submit(service);

    expect(result.status, WorkLogSubmitStatus.alreadySubmitted);
    expect(service.queriedDates, [_entry.date]);
    expect(
      (await StorageService().loadBossHours('2026-09'))[_entry.date],
      7.25,
    );
    expect(await StorageService().loadWorkLogObjectId(_entry.date), isNull);
  });

  for (final invalid in <double?>[null, 0]) {
    test('提交后复读返回 $invalid 时保留旧记录，不用输入工时猜测实际合计', () async {
      await StorageService().saveBossHoursForDate(_entry.date, 6.5);
      final service = _SubmitService(
        submitReply: '{"ok":true,"objectId":"WORKLOG_1"}',
        query: (_) async => invalid,
      );

      final result = await _submit(service);

      expect(result.status, WorkLogSubmitStatus.submitted);
      expect(service.queriedDates, [_entry.date]);
      expect(
        (await StorageService().loadBossHours('2026-09'))[_entry.date],
        6.5,
      );
    });
  }

  test('提交后查询抛错不把已确认成功改成失败或重复执行提交', () async {
    final service = _SubmitService(
      submitReply: '{"ok":true,"objectId":"WORKLOG_1"}',
      query: (_) async => throw StateError('离线'),
    );

    final result = await _submit(service);

    expect(result.status, WorkLogSubmitStatus.submitted);
    expect(service.submitCalls, 1);
    expect(service.queriedDates, [_entry.date]);
    expect(await StorageService().hasBossHoursForDate(_entry.date), isFalse);
    expect(
      await StorageService().loadWorkLogObjectId(_entry.date),
      'WORKLOG_1',
    );
  });

  test('去重后复读失败仍保留去重查询确认的工时', () async {
    final service = _SubmitService(
      submitReply: '{"alreadySubmitted":true,"existingHours":6.5}',
      query: (_) async => throw StateError('离线'),
    );

    final result = await _submit(service);

    expect(result.status, WorkLogSubmitStatus.alreadySubmitted);
    expect((await StorageService().loadBossHours('2026-09'))[_entry.date], 6.5);
  });

  test('提交失败或结果未知时不触发保存后的刷新', () async {
    for (final reply in ['{"failed":true}', '{"deferred":true}']) {
      final service = _SubmitService(submitReply: reply, query: (_) async => 8);
      final result = await _submit(service);
      expect(result.ok, isFalse);
      expect(service.queriedDates, isEmpty);
      expect(await StorageService().hasBossHoursForDate(_entry.date), isFalse);
    }
  });
}
