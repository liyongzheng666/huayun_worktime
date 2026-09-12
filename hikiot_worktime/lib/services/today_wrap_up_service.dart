import '../models/today_wrap_up.dart';
import '../utils/date_helper.dart';
import 'boss_session_runner.dart';
import 'boss_hours_auto_refresh_service.dart';
import 'storage_service.dart';
import 'work_log_repository.dart';

typedef TodayBossHoursLoader =
    Future<BossSessionResult<double>> Function(String date);

/// 只读今日素材和单日 BOSS 状态，不触发提交，也不另建凭据或缓存存储。
class TodayWrapUpService {
  TodayWrapUpService({
    StorageService? storage,
    WorkLogRepository? repository,
    TodayBossHoursLoader? loadBossHours,
    BossHoursAutoRefreshService? bossHoursRefresh,
    DateTime Function()? now,
  }) : _storage = storage ?? StorageService(),
       _repository = repository ?? WorkLogRepository(storage: storage),
       _loadBossHours =
           loadBossHours ??
           ((date) => (bossHoursRefresh ?? BossHoursAutoRefreshService.shared)
               .refreshDate(DateTime.parse(date))),
       _now = now ?? DateTime.now;

  final StorageService _storage;
  final WorkLogRepository _repository;
  final TodayBossHoursLoader _loadBossHours;
  final DateTime Function() _now;
  final Map<String, Future<TodayWrapUpData>> _inFlight = {};

  Future<TodayWrapUpData> loadCached(DateTime date) async {
    final entries = await _repository.loadAll();
    final month = DateHelper.formatMonth(date);
    final cache = await _storage.loadBossHours(month);
    final cachedAt = await _storage.loadBossHoursRefreshedAt(month);
    return TodayWrapUpData(
      date: date,
      hasEntry: entries.containsKey(DateHelper.formatDate(date)),
      entry: entries[DateHelper.formatDate(date)],
      cachedBossHours: cache[DateHelper.formatDate(date)],
      cachedAt: cachedAt,
    );
  }

  /// 同日并发合并；下一次刷新重新查询，旧成功结果不能掩盖本次网络失败。
  Future<TodayWrapUpData> load(DateTime date) {
    final key = DateHelper.formatDate(date);
    return _inFlight.putIfAbsent(
      key,
      () => _load(date).whenComplete(() {
        _inFlight.remove(key);
      }),
    );
  }

  Future<TodayWrapUpData> _load(DateTime date) async {
    var local = await loadCached(date);
    BossSessionResult<double> result;
    try {
      result = await _loadBossHours(DateHelper.formatDate(date));
    } catch (_) {
      result = const BossSessionResult(BossSessionStatus.failed);
    }
    // 后台查询期间用户可能导入素材或提交日志，返回前重读，避免旧快照回退。
    local = await loadCached(date);
    final hours = result.value;
    final confirmed =
        result.isOk && hours != null && hours.isFinite && hours >= 0;
    return TodayWrapUpData(
      date: date,
      hasEntry: local.hasEntry,
      entry: local.entry,
      bossStatus: confirmed
          ? hours > 0
                ? TodayBossStatus.submitted
                : TodayBossStatus.unsubmitted
          : result.status == BossSessionStatus.noSession
          ? TodayBossStatus.noSession
          : TodayBossStatus.unknown,
      bossHours: confirmed ? hours : null,
      checkedAt: confirmed ? _now() : null,
      cachedBossHours: local.cachedBossHours,
      cachedAt: local.cachedAt,
    );
  }
}
