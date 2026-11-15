import 'dart:convert';

import '../utils/date_helper.dart';
import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/perf_frame_probe.dart';
import 'boss_session_runner.dart';
import 'storage_service.dart';
import 'work_log_submit_service.dart';

typedef BossMonthLoader = Future<Map<String, double>?> Function(DateTime month);
typedef BossMonthResultLoader =
    Future<BossSessionResult<Map<String, double>>> Function(DateTime month);
typedef BossDayLoader =
    Future<BossSessionResult<double>> Function(DateTime date);
typedef RefreshClock = DateTime Function();

enum BossHoursAutoRefreshStatus { updated, fresh, unavailable }

class BossHoursAutoRefreshResult {
  const BossHoursAutoRefreshResult({
    required this.status,
    required this.hours,
    this.failureReason,
  });

  final BossHoursAutoRefreshStatus status;
  final Map<String, double> hours;
  final BossSessionStatus? failureReason;
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
    BossMonthResultLoader? loadMonthResult,
    BossDayLoader? loadDay,
    this.maxAge = const Duration(minutes: 15),
    this.failureBackoff = const Duration(minutes: 5),
    this.passiveMaxAge = const Duration(seconds: 30),
    RefreshClock? now,
  }) : _storage = storage ?? StorageService(),
       _loadMonth =
           loadMonthResult ??
           (loadMonth == null
               ? _defaultLoadMonth
               : ((month) async => BossSessionResult(
                   BossSessionStatus.ok,
                   await loadMonth(month),
                 ))),
       _loadDay = loadDay ?? _defaultLoadDay,
       _now = now ?? DateTime.now;

  static final BossHoursAutoRefreshService shared =
      BossHoursAutoRefreshService();

  final StorageService _storage;
  final BossMonthResultLoader _loadMonth;
  final BossDayLoader _loadDay;
  final Duration maxAge;
  final Duration failureBackoff;
  final Duration passiveMaxAge;
  final RefreshClock _now;
  final _dayInFlight = <String, _DayQuery>{};
  final _trailingDay = <String, Future<BossSessionResult<double>>>{};
  final _inFlight = <String, _MonthQuery>{};
  final _dayFailures = <String, _QueryFailure>{};
  final _monthFailures = <String, _QueryFailure>{};

  Future<_QueryIdentity?> _identity() async {
    try {
      final revision = await _storage.loadAuthRevision();
      final scope = await _storage.loadBossCredentialScope();
      if (revision != await _storage.loadAuthRevision()) return null;
      return _QueryIdentity(revision, scope);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isCurrent(_QueryIdentity identity) async =>
      (await _identity())?.key == identity.key;

  bool _backingOff(_QueryFailure? failure) {
    if (failure == null) return false;
    final age = _now().difference(failure.at);
    return !age.isNegative && age < failureBackoff;
  }

  Future<BossHoursAutoRefreshResult> refreshIfStale(
    DateTime month, {
    bool force = false,
  }) async {
    final identity = await _identity();
    if (identity == null) return _unavailable();
    return _refreshMonthScoped(
      identity,
      DateTime(month.year, month.month),
      force,
    );
  }

  Future<BossHoursAutoRefreshResult> _refreshMonthScoped(
    _QueryIdentity identity,
    DateTime month,
    bool force,
  ) {
    final monthKey = DateHelper.formatMonth(month);
    final key = '${identity.key}/$monthKey';
    final running = _inFlight[key];
    if (running != null) {
      if (!force) return running.future;
      // 若前一轮只读了缓存/退避，force仍须真正查询；已在远端查询则合并。
      return running.future.then(
        (result) => running.networkStarted
            ? result
            : _refreshMonthScoped(identity, month, true),
      );
    }
    final query = _MonthQuery();
    query.future = _refreshMonth(identity, month, monthKey, key, force, query);
    _inFlight[key] = query;
    query.future.whenComplete(() {
      if (identical(_inFlight[key], query)) _inFlight.remove(key);
    });
    return query.future;
  }

  BossHoursAutoRefreshResult _unavailable({
    Map<String, double> hours = const {},
    BossSessionStatus? reason,
  }) => BossHoursAutoRefreshResult(
    status: BossHoursAutoRefreshStatus.unavailable,
    hours: hours,
    failureReason: reason,
  );

  Future<BossMonthSnapshot> _snapshot(
    _QueryIdentity identity,
    String monthKey, {
    Duration? age,
  }) => _storage.loadBossMonthSnapshot(
    monthKey,
    now: _now(),
    maxAge: age ?? maxAge,
    expectedScope: identity.scope,
  );

  bool _complete(BossMonthSnapshot snapshot, DateTime month) =>
      snapshot.isValid &&
      snapshot.consistent &&
      snapshot.revision == StorageService.bossHoursRevision &&
      snapshot.confirmedDates.length ==
          DateTime(month.year, month.month + 1, 0).day &&
      snapshot.ownedDates.length ==
          DateTime(month.year, month.month + 1, 0).day;

  Future<BossHoursAutoRefreshResult> _refreshMonth(
    _QueryIdentity identity,
    DateTime month,
    String monthKey,
    String key,
    bool force,
    _MonthQuery query,
  ) async {
    var cached = <String, double>{};
    try {
      var snapshot = await _snapshot(identity, monthKey);
      cached = snapshot.hours;
      if (!await _isCurrent(identity)) return _unavailable();
      if (!force) {
        final failure = _monthFailures[key];
        if (_backingOff(failure)) {
          return _unavailable(hours: cached, reason: failure!.reason);
        }
        if (_complete(snapshot, month)) {
          return BossHoursAutoRefreshResult(
            status: BossHoursAutoRefreshStatus.fresh,
            hours: cached,
          );
        }
        // 旧调用方只更新一日时，仅重核少量所有权/证明孔洞，不再查询整月31日。
        final days = DateTime(month.year, month.month + 1, 0).day;
        final missing = <DateTime>[
          for (var day = 1; day <= days; day++)
            if (!snapshot.ownedDates.contains(
                  '$monthKey-${day.toString().padLeft(2, '0')}',
                ) ||
                !snapshot.confirmedDates.contains(
                  '$monthKey-${day.toString().padLeft(2, '0')}',
                ))
              DateTime(month.year, month.month, day),
        ];
        if (snapshot.isValid &&
            snapshot.consistent &&
            snapshot.ownedDates.isNotEmpty &&
            missing.length <= 3) {
          query.networkStarted = true;
          await Future.wait(
            missing.map((date) => _refreshDayScoped(identity, date, true)),
          );
          snapshot = await _snapshot(identity, monthKey);
          if (!await _isCurrent(identity)) return _unavailable();
          if (_complete(snapshot, month)) {
            return BossHoursAutoRefreshResult(
              status: BossHoursAutoRefreshStatus.updated,
              hours: snapshot.hours,
            );
          }
          _monthFailures[key] = _QueryFailure(_now(), BossSessionStatus.failed);
          return _unavailable(
            hours: snapshot.hours,
            reason: BossSessionStatus.failed,
          );
        }
      }
      query.networkStarted = true;
      final revision = StorageService.bossHoursRevision;
      final result = await _loadMonth(month);
      if (!await _isCurrent(identity)) return _unavailable();
      final loaded = result.value;
      if (!result.isOk || loaded == null) {
        final reason = result.status == BossSessionStatus.noSession
            ? BossSessionStatus.noSession
            : BossSessionStatus.failed;
        _monthFailures[key] = _QueryFailure(_now(), reason);
        return _unavailable(hours: cached, reason: reason);
      }
      await _storage.saveBossHours(
        monthKey,
        loaded,
        refreshedAt: _now(),
        expectedRevision: revision,
        expectedAuthRevision: identity.authRevision,
        expectedScope: identity.scope,
      );
      if (!await _isCurrent(identity)) return _unavailable();
      _monthFailures.remove(key);
      final current = await _snapshot(identity, monthKey);
      return BossHoursAutoRefreshResult(
        status: BossHoursAutoRefreshStatus.updated,
        hours: current.hours,
      );
    } catch (_) {
      _monthFailures[key] = _QueryFailure(_now(), BossSessionStatus.failed);
      return _unavailable(hours: cached, reason: BossSessionStatus.failed);
    }
  }

  /// 被动页面读取可复用30秒内同身份的确认；force绕过缓存和失败退避。
  /// 同轮force只保留一轮后续查询，不按点击次数串行排队。
  Future<BossSessionResult<double>> refreshDate(
    DateTime date, {
    bool force = false,
  }) async {
    final identity = await _identity();
    if (identity == null) {
      return const BossSessionResult(BossSessionStatus.failed);
    }
    final normalized = DateTime(date.year, date.month, date.day);
    final monthKey = '${identity.key}/${DateHelper.formatMonth(normalized)}';
    final monthly = _inFlight[monthKey];
    if (!force && monthly != null) {
      final result = await monthly.future;
      if (!await _isCurrent(identity)) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      if (result.status == BossHoursAutoRefreshStatus.unavailable) {
        return BossSessionResult(
          result.failureReason ?? BossSessionStatus.failed,
        );
      }
    }
    return _refreshDayScoped(identity, normalized, force);
  }

  Future<BossSessionResult<double>> _refreshDayScoped(
    _QueryIdentity identity,
    DateTime date,
    bool force,
  ) {
    final dateKey = DateHelper.formatDate(date);
    final key = '${identity.key}/$dateKey';
    final running = _dayInFlight[key];
    if (running != null) {
      if (!force ||
          (running.forced &&
              running.revision == StorageService.bossHoursRevision)) {
        return running.future;
      }
      final queued = _trailingDay[key];
      if (queued != null) return queued;
      late final Future<BossSessionResult<double>> trailing;
      trailing = running.future.then((_) {
        if (identical(_trailingDay[key], trailing)) _trailingDay.remove(key);
        return _refreshDayScoped(identity, date, true);
      });
      _trailingDay[key] = trailing;
      return trailing;
    }
    final query = _DayQuery(force, StorageService.bossHoursRevision);
    query.future = _refreshDay(identity, date, dateKey, key, force, query);
    _dayInFlight[key] = query;
    query.future.whenComplete(() {
      if (identical(_dayInFlight[key], query)) _dayInFlight.remove(key);
    });
    return query.future;
  }

  Future<BossSessionResult<double>> _refreshDay(
    _QueryIdentity identity,
    DateTime date,
    String dateKey,
    String key,
    bool force,
    _DayQuery query,
  ) async {
    try {
      if (!await _isCurrent(identity)) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      if (!force) {
        final failure = _dayFailures[key];
        if (_backingOff(failure)) return BossSessionResult(failure!.reason);
        final snapshot = await _snapshot(
          identity,
          dateKey.substring(0, 7),
          age: passiveMaxAge,
        );
        if (!await _isCurrent(identity)) {
          return const BossSessionResult(BossSessionStatus.failed);
        }
        if (snapshot.isValid &&
            snapshot.consistent &&
            snapshot.revision == StorageService.bossHoursRevision &&
            snapshot.confirmedDates.contains(dateKey) &&
            snapshot.ownedDates.contains(dateKey)) {
          return BossSessionResult(
            BossSessionStatus.ok,
            snapshot.hours[dateKey] ?? 0,
          );
        }
      }
      query.revision = StorageService.bossHoursRevision;
      final result = await _loadDay(date);
      if (!await _isCurrent(identity)) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      final hours = result.value;
      if (!result.isOk || hours == null || !hours.isFinite || hours < 0) {
        final reason = result.status == BossSessionStatus.noSession
            ? BossSessionStatus.noSession
            : BossSessionStatus.failed;
        _dayFailures[key] = _QueryFailure(_now(), reason);
        return BossSessionResult(reason);
      }
      await _storage.saveBossHoursForDate(
        dateKey,
        hours,
        refreshedAt: _now(),
        expectedRevision: query.revision,
        expectedAuthRevision: identity.authRevision,
        expectedScope: identity.scope,
      );
      if (!await _isCurrent(identity)) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      final snapshot = await _snapshot(identity, dateKey.substring(0, 7));
      if (!snapshot.isValid ||
          !snapshot.consistent ||
          !snapshot.knownDates.contains(dateKey)) {
        return const BossSessionResult(BossSessionStatus.failed);
      }
      query.revision = snapshot.revision;
      _dayFailures.remove(key);
      return BossSessionResult(
        BossSessionStatus.ok,
        snapshot.hours[dateKey] ?? 0,
      );
    } catch (_) {
      _dayFailures[key] = _QueryFailure(_now(), BossSessionStatus.failed);
      return const BossSessionResult(BossSessionStatus.failed);
    }
  }

  static Future<BossSessionResult<double>> _defaultLoadDay(DateTime date) =>
      BossSessionRunner.run<double>(
        (controller) => WorkLogSubmitService(
          controller,
        ).queryExistingHours(DateHelper.formatDate(date)),
      );

  static Future<BossSessionResult<Map<String, double>>> _defaultLoadMonth(
    DateTime month,
  ) => PerfFrameProbe.measure('boss.month.query', () async {
    final result = await BossSessionRunner.run<String>(
      (controller) => WorkLogBossHours.fetchMonth(
        controller: controller,
        year: month.year,
        month: month.month,
        captureStoreName: WorkLogRequestCapture.storeName,
      ),
      timeout: const Duration(seconds: 25),
    );
    if (!result.isOk) return BossSessionResult(result.status);
    final hours = WorkLogBossHours.parseSuccessfulResult(result.value);
    return BossSessionResult(
      hours == null ? BossSessionStatus.failed : BossSessionStatus.ok,
      hours,
    );
  });
}

class _QueryIdentity {
  _QueryIdentity(this.authRevision, this.scope);
  final int authRevision;
  final String? scope;
  String get key => jsonEncode([authRevision, scope]);
}

class _DayQuery {
  _DayQuery(this.forced, this.revision);
  final bool forced;
  int revision;
  late final Future<BossSessionResult<double>> future;
}

class _MonthQuery {
  bool networkStarted = false;
  late final Future<BossHoursAutoRefreshResult> future;
}

class _QueryFailure {
  _QueryFailure(this.at, this.reason);
  final DateTime at;
  final BossSessionStatus reason;
}
