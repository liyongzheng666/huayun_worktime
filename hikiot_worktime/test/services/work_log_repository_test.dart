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

  group('周条概览 loadWeek', () {
    /// 2026-08-08 是星期六，所在周为 8/3(一) ~ 8/9(日)
    final saturday = DateTime(2026, 8, 8);

    test('返回周一到周日七天，顺序固定', () async {
      final repository = buildRepository();

      final week = await repository.loadWeek(saturday);

      expect(week.length, 7);
      expect(week.first.dateStr, '2026-08-03');
      expect(week.last.dateStr, '2026-08-09');
      expect(week.first.date.weekday, DateTime.monday);
      expect(week.last.date.weekday, DateTime.sunday);
    });

    test('周内任意一天都能定位到同一周', () async {
      final repository = buildRepository();

      for (final day in [3, 5, 8, 9]) {
        final week = await repository.loadWeek(DateTime(2026, 8, day));
        expect(week.first.dateStr, '2026-08-03', reason: '8月$day日');
      }
    });

    test('CSV 里有的日期标记为已填报', () async {
      final repository = buildRepository();
      await repository.importFromCsv(csv);

      final week = await repository.loadWeek(saturday);
      final byDate = {for (final d in week) d.dateStr: d};

      expect(byDate['2026-08-04']!.hasEntry, isTrue);
      expect(byDate['2026-08-05']!.hasEntry, isTrue);
      expect(byDate['2026-08-06']!.hasEntry, isFalse);
    });

    test('本地没有月度缓存时工时为 null，而不是 0', () async {
      // 「还没同步」和「当天没上班」是两回事，周条上要能分开显示
      final repository = buildRepository();

      final week = await repository.loadWeek(saturday);

      expect(week.every((d) => d.hours == null), isTrue);
      expect(week.every((d) => d.hasHours), isFalse);
    });

    test('有月度缓存时读出当天工时', () async {
      final storage = StorageService();
      await storage.saveTeamContext(teamNo: 'team-1');
      await storage.saveMonthlyData('team-1', '2026-08', {
        '2026-08-04': {'hours': 11.1},
        '2026-08-05': {'hours': 0.0},
      });

      final week = await WorkLogRepository(
        storage: storage,
        loadWorkHours: (_) async => const WorkLogHours(),
      ).loadWeek(saturday);
      final byDate = {for (final d in week) d.dateStr: d};

      expect(byDate['2026-08-04']!.hours, 11.1);
      expect(byDate['2026-08-04']!.hasHours, isTrue);
      // 缓存里明确是 0 —— 有数据但没工时，与「未同步」不同
      expect(byDate['2026-08-05']!.hours, 0.0);
      expect(byDate['2026-08-05']!.hasHours, isFalse);
      expect(byDate['2026-08-06']!.hours, isNull);
    });

    test('已提交与「CSV 里有素材」是两回事', () async {
      // 这是本页最容易误导人的地方：导入 CSV 只是准备好素材，
      // 一条都没提交时也会有 hasEntry，绝不能据此认为已完成。
      final storage = StorageService();
      final repository = WorkLogRepository(
        storage: storage,
        loadWorkHours: (_) async => const WorkLogHours(),
      );
      await repository.importFromCsv(csv);
      await storage.saveBossHours('2026-08', {'2026-08-04': 8.0});

      final week = await repository.loadWeek(saturday);
      final byDate = {for (final d in week) d.dateStr: d};

      // 8-04：CSV 有、BOSS 也有 → 已提交
      expect(byDate['2026-08-04']!.hasEntry, isTrue);
      expect(byDate['2026-08-04']!.isSubmitted, isTrue);

      // 8-05：CSV 有、BOSS 没有 → 素材就绪但**未**提交
      expect(byDate['2026-08-05']!.hasEntry, isTrue);
      expect(byDate['2026-08-05']!.isSubmitted, isFalse);
    });

    test('BOSS 工时为 0 或未同步都不算已提交', () async {
      final storage = StorageService();
      await storage.saveBossHours('2026-08', {'2026-08-04': 0.0});

      final week = await WorkLogRepository(
        storage: storage,
        loadWorkHours: (_) async => const WorkLogHours(),
      ).loadWeek(saturday);
      final byDate = {for (final d in week) d.dateStr: d};

      expect(byDate['2026-08-04']!.isSubmitted, isFalse);
      // 未同步过的日期 bossHours 为 null，同样不算已提交
      expect(byDate['2026-08-06']!.bossHours, isNull);
      expect(byDate['2026-08-06']!.isSubmitted, isFalse);
    });

    test('从没同步过 BOSS 的月份标记为未同步', () async {
      // 「没同步过」和「同步过但当天没填」必须分开，
      // 否则界面会把不知道的事说成没做。
      final repository = buildRepository();

      final week = await repository.loadWeek(saturday);

      expect(week.every((d) => d.bossSynced), isFalse);
      expect(week.every((d) => d.bossHours == null), isTrue);
    });

    test('同步过的月份即使当天没填，也算已同步', () async {
      final storage = StorageService();
      await storage.saveBossHours('2026-08', {'2026-08-04': 8.0});

      final week = await WorkLogRepository(
        storage: storage,
        loadWorkHours: (_) async => const WorkLogHours(),
      ).loadWeek(saturday);
      final byDate = {for (final d in week) d.dateStr: d};

      expect(byDate['2026-08-04']!.bossSynced, isTrue);
      // 8-06 没填，但所属月份确实同步过，因此「未提交」是可信结论
      expect(byDate['2026-08-06']!.bossSynced, isTrue);
      expect(byDate['2026-08-06']!.isSubmitted, isFalse);
    });

    test('跨月的那一周会读取两个月的缓存', () async {
      // 2026-08-31 是星期一，该周跨到 9 月
      final storage = StorageService();
      await storage.saveTeamContext(teamNo: 'team-1');
      await storage.saveMonthlyData('team-1', '2026-08', {
        '2026-08-31': {'hours': 8.0},
      });
      await storage.saveMonthlyData('team-1', '2026-09', {
        '2026-09-01': {'hours': 9.0},
      });

      final week = await WorkLogRepository(
        storage: storage,
        loadWorkHours: (_) async => const WorkLogHours(),
      ).loadWeek(DateTime(2026, 8, 31));
      final byDate = {for (final d in week) d.dateStr: d};

      expect(byDate['2026-08-31']!.hours, 8.0);
      expect(byDate['2026-09-01']!.hours, 9.0);
    });
  });
}
