import '../utils/date_helper.dart';
import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_request_capture.dart';
import 'boss_session_runner.dart';
import 'storage_service.dart';

typedef BossMonthLoader = Future<Map<String, double>?> Function(DateTime month);
typedef RefreshClock = DateTime Function();

enum BossHoursAutoRefreshStatus { updated, fresh, unavailable }

class BossHoursAutoRefreshResult {
  const BossHoursAutoRefreshResult({required this.status, required this.hours});

  final BossHoursAutoRefreshStatus status;
  final Map<String, double> hours;
}

/// BOSS 月度工时的无感刷新器。
///
/// 页面先读本地缓存立即展示；缓存超过 [maxAge] 后才在隐藏 WebView 中更新。
/// 无登录态或网络失败时静默保留旧缓存，不弹窗、不清空页面。相同月份的并发请求
/// 合并为同一个 Future，避免月度页和工作日志页同时打开两个 WebView、逐日请求两遍。
class BossHoursAutoRefreshService {
  BossHoursAutoRefreshService({
    StorageService? storage,
    BossMonthLoader? loadMonth,
    this.maxAge = const Duration(minutes: 15),
    this.failureBackoff = const Duration(minutes: 5),
    RefreshClock? now,
  }) : _storage = storage ?? StorageService(),
       _loadMonth = loadMonth ?? _defaultLoadMonth,
       _now = now ?? DateTime.now;

  static final BossHoursAutoRefreshService shared =
      BossHoursAutoRefreshService();

  final StorageService _storage;
  final BossMonthLoader _loadMonth;
  final Duration maxAge;
  final Duration failureBackoff;
  final RefreshClock _now;
  final Map<String, Future<BossHoursAutoRefreshResult>> _inFlight = {};
  final Map<String, DateTime> _lastAttempt = {};

  Future<BossHoursAutoRefreshResult> refreshIfStale(
    DateTime month, {
    bool force = false,
  }) {
    final normalized = DateTime(month.year, month.month);
    final monthKey = DateHelper.formatMonth(normalized);
    final running = _inFlight[monthKey];
    if (running != null) return running;

    final future = _refresh(normalized, monthKey, force: force);
    _inFlight[monthKey] = future;
    future.whenComplete(() => _inFlight.remove(monthKey));
    return future;
  }

  Future<BossHoursAutoRefreshResult> _refresh(
    DateTime month,
    String monthKey, {
    required bool force,
  }) async {
    var cached = <String, double>{};
    try {
      final now = _now();
      cached = await _storage.loadBossHours(monthKey);
      if (!force) {
        final refreshedAt = await _storage.loadBossHoursRefreshedAt(monthKey);
        final cacheAge = refreshedAt == null
            ? null
            : now.difference(refreshedAt);
        if (cacheAge != null && !cacheAge.isNegative && cacheAge < maxAge) {
          return BossHoursAutoRefreshResult(
            status: BossHoursAutoRefreshStatus.fresh,
            hours: cached,
          );
        }
        final lastAttempt = _lastAttempt[monthKey];
        final attemptAge = lastAttempt == null
            ? null
            : now.difference(lastAttempt);
        if (attemptAge != null &&
            !attemptAge.isNegative &&
            attemptAge < failureBackoff) {
          return BossHoursAutoRefreshResult(
            status: BossHoursAutoRefreshStatus.unavailable,
            hours: cached,
          );
        }
      }

      _lastAttempt[monthKey] = now;
      final loaded = await _loadMonth(month);
      if (loaded == null) {
        return BossHoursAutoRefreshResult(
          status: BossHoursAutoRefreshStatus.unavailable,
          hours: cached,
        );
      }

      await _storage.saveBossHours(monthKey, loaded, refreshedAt: now);
      return BossHoursAutoRefreshResult(
        status: BossHoursAutoRefreshStatus.updated,
        hours: loaded,
      );
    } catch (_) {
      // 自动刷新不能把异常冒泡到全局，更不能清空已有缓存。
      return BossHoursAutoRefreshResult(
        status: BossHoursAutoRefreshStatus.unavailable,
        hours: cached,
      );
    }
  }

  static Future<Map<String, double>?> _defaultLoadMonth(DateTime month) async {
    final result = await BossSessionRunner.run<String>((controller) async {
      final raw = await controller.evaluateJavascript(
        source: WorkLogBossHours.buildFetchMonthScript(
          year: month.year,
          month: month.month,
          captureStoreName: WorkLogRequestCapture.storeName,
        ),
      );
      return raw?.toString();
    }, timeout: const Duration(seconds: 25));
    if (!result.isOk) return null;
    return WorkLogBossHours.parseSuccessfulResult(result.value);
  }
}
