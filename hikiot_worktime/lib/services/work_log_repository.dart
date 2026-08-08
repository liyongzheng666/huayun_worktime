import '../utils/date_helper.dart';
import '../utils/work_log_csv_parser.dart';
import 'daily_attendance_repository.dart';
import 'storage_service.dart';

/// 当日实际工时来源，抽成回调便于测试注入。
typedef WorkHoursLoader = Future<WorkLogHours> Function(DateTime date);

/// 某一天的实际打卡工时
class WorkLogHours {
  const WorkLogHours({this.hours, this.checkIn, this.checkOut});

  /// 当日工时，null 表示没有取到打卡数据
  final double? hours;
  final String? checkIn;
  final String? checkOut;

  bool get hasData => hours != null;
}

/// 某一天的填报素材：CSV 条目 + 当日实际工时
///
/// 页面只消费这个对象，不直接拼装 CSV 与考勤两份数据。
class WorkLogDraft {
  const WorkLogDraft({
    required this.date,
    required this.hours,
    this.entry,
  });

  /// yyyy-MM-dd
  final String date;

  /// 该日的 CSV 条目，null 表示 CSV 里没有这一天
  final WorkLogEntry? entry;

  /// 该日实际打卡工时
  final WorkLogHours hours;

  bool get hasEntry => entry != null;
}

/// 周条上单日的概览
class WorkLogDaySummary {
  const WorkLogDaySummary({
    required this.date,
    required this.dateStr,
    required this.hasEntry,
    this.hours,
    this.bossHours,
    this.bossSynced = false,
  });

  final DateTime date;

  /// yyyy-MM-dd
  final String dateStr;

  /// CSV 里有没有这天的素材。
  ///
  /// **这不等于「已提交」**——导入 CSV 只是把素材准备好，
  /// 真正提交与否要看 [bossHours]。早期把两者混为一谈，
  /// 导致导入后整月都显示成已完成。
  final bool hasEntry;

  /// 打卡工时。null 表示本地还没有这天的数据，**不等于 0**——
  /// 周条上要能区分「这天没上班」和「还没同步过」。
  final double? hours;

  /// BOSS 里已填报的工时。
  final double? bossHours;

  /// 该日所属月份是否同步过 BOSS 工时。
  ///
  /// 没同步过时 [bossHours] 恒为 null，但那只代表**不知道**，
  /// 不能据此判定未提交——否则从没同步过的月份会整片标成欠账。
  final bool bossSynced;

  bool get hasHours => hours != null && hours! > 0;

  /// 是否确实已提交到 BOSS。
  bool get isSubmitted => bossHours != null && bossHours! > 0;
}

/// 导入结果
class WorkLogImportResult {
  const WorkLogImportResult({
    required this.importedCount,
    required this.firstDate,
    required this.lastDate,
  });

  final int importedCount;
  final String firstDate;
  final String lastDate;
}

/// 工作日志仓储
///
/// 职责单一：管理「导入的 CSV 日志」的解析、落盘与按日期查询，
/// 并在需要时与考勤工时合并成一份填报素材。
/// 不负责任何 UI 与网页填充逻辑。
class WorkLogRepository {
  WorkLogRepository({StorageService? storage, WorkHoursLoader? loadWorkHours})
    : _storage = storage ?? StorageService(),
      _loadWorkHours = loadWorkHours ?? _defaultLoadWorkHours;

  final StorageService _storage;
  final WorkHoursLoader _loadWorkHours;

  /// 从 CSV 文本导入，整体覆盖此前导入的内容。
  ///
  /// 解析失败时抛 [WorkLogCsvException]，其 message 可直接展示给用户。
  Future<WorkLogImportResult> importFromCsv(
    String csvContent, {
    String? sourceName,
  }) async {
    final parsed = WorkLogCsvParser.parse(csvContent);

    await _storage.saveWorkLogEntries(
      parsed.map((date, entry) => MapEntry(date, entry.toJson())),
      sourceName: sourceName,
    );

    final dates = parsed.keys.toList()..sort();
    return WorkLogImportResult(
      importedCount: parsed.length,
      firstDate: dates.first,
      lastDate: dates.last,
    );
  }

  Future<Map<String, WorkLogEntry>> loadAll() async {
    final raw = await _storage.loadWorkLogEntries();
    return raw.map((date, json) => MapEntry(date, WorkLogEntry.fromJson(json)));
  }

  Future<WorkLogEntry?> loadEntry(String dateStr) async {
    final raw = await _storage.loadWorkLogEntries();
    final json = raw[dateStr];
    return json == null ? null : WorkLogEntry.fromJson(json);
  }

  /// 读取某天的完整填报素材（CSV 内容 + 实际工时）。
  Future<WorkLogDraft> loadDraft(DateTime date) async {
    final dateStr = DateHelper.formatDate(date);
    return WorkLogDraft(
      date: dateStr,
      entry: await loadEntry(dateStr),
      hours: await _loadWorkHours(date),
    );
  }

  /// 读取 [anyDayInWeek] 所在那一周（周一至周日）的概览。
  ///
  /// 工时取自**本地月度缓存**而非逐日调接口：周条一次要七天，
  /// 逐日请求就是七次网络往返，滑动切周时更会成倍放大。
  /// 缓存里没有的日期返回 null 工时，界面显示为「未同步」，
  /// 而不是伪装成 0 小时。
  ///
  /// 一周可能横跨两个月，因此按需读取涉及到的每个月。
  Future<List<WorkLogDaySummary>> loadWeek(DateTime anyDayInWeek) async {
    final monday = DateTime(
      anyDayInWeek.year,
      anyDayInWeek.month,
      anyDayInWeek.day,
    ).subtract(Duration(days: anyDayInWeek.weekday - 1));

    final entries = await _storage.loadWorkLogEntries();
    final teamNo = await _storage.loadTeamNo();

    // BOSS 已填报工时按月存放，与月历页共用同一份缓存
    final bossCache = <String, Map<String, double>>{};
    final bossSyncedCache = <String, bool>{};
    Future<Map<String, double>> bossData(DateTime date) async {
      final monthKey = DateHelper.formatMonth(date);
      if (bossCache.containsKey(monthKey)) return bossCache[monthKey]!;

      bossSyncedCache[monthKey] = await _storage.hasBossHoursSynced(monthKey);
      final loaded = await _storage.loadBossHours(monthKey);
      bossCache[monthKey] = loaded;
      return loaded;
    }

    // 同一个月只读一次（跨月的那一周会涉及两个月）
    final monthCache = <String, Map<String, Map<String, dynamic>>?>{};
    Future<Map<String, Map<String, dynamic>>?> monthData(DateTime date) async {
      if (teamNo == null) return null;
      final monthKey = DateHelper.formatMonth(date);
      if (monthCache.containsKey(monthKey)) return monthCache[monthKey];

      final loaded = await _storage.loadMonthlyData(teamNo, monthKey);
      monthCache[monthKey] = loaded;
      return loaded;
    }

    final result = <WorkLogDaySummary>[];
    for (var i = 0; i < 7; i++) {
      final date = monday.add(Duration(days: i));
      final dateStr = DateHelper.formatDate(date);
      final data = await monthData(date);
      final boss = await bossData(date);

      result.add(
        WorkLogDaySummary(
          date: date,
          dateStr: dateStr,
          hasEntry: entries.containsKey(dateStr),
          hours: (data?[dateStr]?['hours'] as num?)?.toDouble(),
          bossHours: boss[dateStr],
          bossSynced: bossSyncedCache[DateHelper.formatMonth(date)] ?? false,
        ),
      );
    }
    return result;
  }

  /// 返回 (来源文件名, 导入时间)。
  Future<(String?, DateTime?)> loadMeta() => _storage.loadWorkLogMeta();

  Future<void> clear() => _storage.clearWorkLogEntries();

  /// 默认工时来源：复用现有的每日考勤仓储，保证与「每日工时」页口径一致。
  static Future<WorkLogHours> _defaultLoadWorkHours(DateTime date) async {
    try {
      final result = await DailyAttendanceRepository().load(date);
      if (result.status != DailyAttendanceLoadStatus.loaded) {
        return const WorkLogHours();
      }

      final dayData = result.dayData;
      return WorkLogHours(
        hours: (dayData['hours'] as num?)?.toDouble(),
        checkIn: dayData['checkIn'] as String?,
        checkOut: dayData['checkOut'] as String?,
      );
    } catch (e) {
      // 取不到工时不应阻断日志填报，页面会显示为「未获取到」。
      return const WorkLogHours();
    }
  }
}
