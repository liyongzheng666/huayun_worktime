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
