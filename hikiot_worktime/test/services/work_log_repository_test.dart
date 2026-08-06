import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const header = '日期,项目名称,BOSS工作类型,项目阶段,阶段活动,标题,工作内容';
  const csv =
      '$header\n'
      '2026-08-04,比亚迪项目,研发,软件编码阶段,软件编码,接口模块编码,"完成接口开发。1) 实现逻辑，覆盖场景。"\n'
      '2026-08-05,比亚迪项目,设计,无,无,数据模块编码,"完成数据开发。"';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  WorkLogRepository buildRepository({WorkHoursLoader? loadWorkHours}) {
    return WorkLogRepository(
      storage: StorageService(),
      loadWorkHours:
          loadWorkHours ?? (_) async => const WorkLogHours(),
    );
  }

  group('导入与查询', () {
    test('导入 CSV 后可按日期取回条目，含逗号的工作内容不丢失', () async {
      final repository = buildRepository();

      final result = await repository.importFromCsv(csv, sourceName: '八月.csv');

      expect(result.importedCount, 2);
      expect(result.firstDate, '2026-08-04');
      expect(result.lastDate, '2026-08-05');

      final entry = await repository.loadEntry('2026-08-04');
      expect(entry, isNotNull);
      expect(entry!.title, '接口模块编码');
      expect(entry.content, contains('覆盖场景'));
      expect(entry.workType, '研发');
    });

    test('导入后重启（新建仓储实例）仍能读到数据', () async {
      await buildRepository().importFromCsv(csv);

      final entry = await buildRepository().loadEntry('2026-08-05');

      expect(entry?.title, '数据模块编码');
      expect(entry?.stage, '无');
    });

    test('再次导入整体覆盖旧数据，不残留上一次的日期', () async {
      final repository = buildRepository();
      await repository.importFromCsv(csv);

      await repository.importFromCsv(
        '$header\n2026-09-01,新项目,测试,无,无,新标题,新内容',
      );

      expect(await repository.loadEntry('2026-08-04'), isNull);
      expect((await repository.loadEntry('2026-09-01'))?.title, '新标题');
      expect((await repository.loadAll()).length, 1);
    });

    test('导入非法 CSV 抛出可展示异常，且不破坏已有数据', () async {
      final repository = buildRepository();
      await repository.importFromCsv(csv);

      await expectLater(
        repository.importFromCsv('完全不是CSV'),
        throwsA(isA<WorkLogCsvException>()),
      );

      expect((await repository.loadEntry('2026-08-04'))?.title, '接口模块编码');
    });

    test('记录来源文件名与导入时间', () async {
      final repository = buildRepository();
      await repository.importFromCsv(csv, sourceName: '八月.csv');

      final (sourceName, importedAt) = await repository.loadMeta();

      expect(sourceName, '八月.csv');
      expect(importedAt, isNotNull);
    });

    test('clear 后条目与元信息一并清空', () async {
      final repository = buildRepository();
      await repository.importFromCsv(csv, sourceName: '八月.csv');

      await repository.clear();

      expect(await repository.loadAll(), isEmpty);
      final (sourceName, importedAt) = await repository.loadMeta();
      expect(sourceName, isNull);
      expect(importedAt, isNull);
    });
  });

  group('填报素材合并', () {
    test('CSV 条目与当日实际工时合并为一份草稿', () async {
      final repository = buildRepository(
        loadWorkHours: (_) async =>
            const WorkLogHours(hours: 8.55, checkIn: '08:47', checkOut: '18:22'),
      );
      await repository.importFromCsv(csv);

      final draft = await repository.loadDraft(DateTime(2026, 8, 4));

      expect(draft.date, '2026-08-04');
      expect(draft.hasEntry, isTrue);
      expect(draft.entry!.title, '接口模块编码');
      expect(draft.hours.hours, 8.55);
      expect(draft.hours.checkIn, '08:47');
      expect(draft.hours.hasData, isTrue);
    });

    test('CSV 里没有该日期时草稿仍返回工时，不抛异常', () async {
      final repository = buildRepository(
        loadWorkHours: (_) async => const WorkLogHours(hours: 8.0),
      );
      await repository.importFromCsv(csv);

      final draft = await repository.loadDraft(DateTime(2026, 8, 2));

      expect(draft.hasEntry, isFalse);
      expect(draft.entry, isNull);
      expect(draft.hours.hours, 8.0);
    });

    test('取不到工时时草稿仍返回 CSV 内容，工时标记为无数据', () async {
      final repository = buildRepository(
        loadWorkHours: (_) async => const WorkLogHours(),
      );
      await repository.importFromCsv(csv);

      final draft = await repository.loadDraft(DateTime(2026, 8, 4));

      expect(draft.hasEntry, isTrue);
      expect(draft.hours.hasData, isFalse);
      expect(draft.hours.hours, isNull);
    });
  });
}
