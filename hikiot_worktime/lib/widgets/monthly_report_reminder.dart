import 'dart:async';

import 'package:flutter/material.dart';

import '../models/monthly_report_balance.dart';
import '../services/monthly_report_balance_service.dart';
import '../services/storage_service.dart';
import '../services/boss_hours_auto_refresh_service.dart';
import '../utils/date_helper.dart';
import 'monthly_report_balance_dialog.dart';
import 'month_end_report_review_dialog.dart';

/// 打开或返回App时读取月底快照；会话准备好后弹出月度差额核对，不提交日报。
class MonthlyReportReminder extends StatefulWidget {
  const MonthlyReportReminder({
    super.key,
    required this.child,
    this.service,
    this.onReview,
    this.autoPromptEnabled = false,
    this.reviewStorage,
    this.synchronizeMonth,
  });

  final Widget child;
  final MonthlyReportBalanceService? service;
  final Future<void> Function(MonthlyReportSnapshot snapshot)? onReview;
  final bool autoPromptEnabled;
  final StorageService? reviewStorage;
  final Future<void> Function(DateTime month)? synchronizeMonth;

  @override
  State<MonthlyReportReminder> createState() => MonthlyReportReminderState();
}

class MonthlyReportReminderState extends State<MonthlyReportReminder>
    with WidgetsBindingObserver {
  late MonthlyReportBalanceService _service;
  MonthlyReportSnapshot? _snapshot;
  String? _dismissedFingerprint;
  int _refreshSequence = 0;
  Future<void>? _refreshInFlight;
  bool _refreshRequested = false;
  bool _reviewing = false;
  bool _prompting = false;
  String? _deferredSignature;
  final Set<String> _reviewedInSession = {};
  late StorageService _reviewStorage;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? MonthlyReportBalanceService();
    _reviewStorage = widget.reviewStorage ?? StorageService();
    WidgetsBinding.instance.addObserver(this);
    StorageService.bossHoursChanges.addListener(_onBossHoursChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(refresh());
    });
  }

  @override
  void didUpdateWidget(covariant MonthlyReportReminder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _service = widget.service ?? MonthlyReportBalanceService();
      unawaited(refresh());
    }
    if (oldWidget.reviewStorage != widget.reviewStorage) {
      _reviewStorage = widget.reviewStorage ?? StorageService();
    }
    if (!oldWidget.autoPromptEnabled && widget.autoPromptEnabled) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    StorageService.bossHoursChanges.removeListener(_onBossHoursChanged);
    _refreshSequence++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _deferredSignature = null;
      unawaited(refresh());
    }
  }

  void _onBossHoursChanged() {
    final changedMonth = StorageService.bossHoursChangedMonth;
    if (changedMonth != null &&
        changedMonth != DateHelper.formatMonth(_service.now)) {
      return;
    }
    unawaited(refresh());
  }

  /// 主页面完成月度考勤刷新后调用，保持提醒与实际缓存一致。
  Future<void> refresh() {
    if (!mounted) return Future<void>.value();
    _refreshSequence++;
    _refreshRequested = true;
    final running = _refreshInFlight;
    if (running != null) return running;
    final future = _drainRefreshes();
    _refreshInFlight = future;
    future.then((_) {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
    return future;
  }

  /// 通知风暴只标记需要重读；保持一次计算在运行，末尾再读最新数据。
  /// 这里只合并展示刷新，提交前服务层校验仍独立读取当前存储。
  Future<void> _drainRefreshes() async {
    while (mounted && _refreshRequested) {
      _refreshRequested = false;
      final sequence = _refreshSequence;
      try {
        final snapshot = await _service.load(_service.now);
        if (!mounted) return;
        if (sequence != _refreshSequence) continue;
        setState(() => _snapshot = snapshot);
        unawaited(_maybePrompt());
      } catch (_) {
        // 正常未知状态由服务层明确返回；意外读取异常不阻塞主页面。
      }
    }
  }

  /// 月末即使差额为零也弹出核对；仅缓存版本更新不会重复打扰已核对摘要。
  Future<void> _maybePrompt() async {
    var snapshot = _snapshot;
    if (!mounted ||
        !widget.autoPromptEnabled ||
        _prompting ||
        _reviewing ||
        snapshot == null ||
        !snapshot.isMonthEnd ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final signature = snapshot.reviewSignature;
    if (_deferredSignature == signature ||
        _reviewedInSession.contains(signature)) {
      return;
    }
    _prompting = true;
    var handled = signature;
    try {
      final saved = await _reviewStorage.loadMonthReportReview(
        DateHelper.formatMonth(snapshot.month),
      );
      if (!mounted ||
          !widget.autoPromptEnabled ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final latest = _snapshot;
      if (latest == null || latest.reviewSignature != signature) return;
      snapshot = latest;
      if (saved == signature) {
        _reviewedInSession.add(signature);
        return;
      }
      final reviewed = await MonthEndReportReviewDialog.show(
        context: context,
        snapshot: snapshot,
        onRefresh: () async {
          final synchronize = widget.synchronizeMonth;
          if (synchronize != null) {
            await synchronize(snapshot!.month);
          } else {
            await BossHoursAutoRefreshService.shared.refreshIfStale(
              snapshot!.month,
              force: true,
            );
          }
          return _service.load(snapshot.month);
        },
        validate: (seen) async {
          final current = await _service.load(seen.month);
          return current.isReady &&
              current.reviewSignature == seen.reviewSignature;
        },
      );
      if (!mounted) return;
      if (reviewed == null) {
        _deferredSignature = signature;
      } else {
        handled = reviewed.reviewSignature;
        await _reviewStorage.saveMonthReportReview(
          DateHelper.formatMonth(reviewed.month),
          handled,
        );
        if (!mounted) return;
        _reviewedInSession.add(handled);
      }
      await refresh();
    } catch (_) {
      if (mounted) {
        _deferredSignature = signature;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('月末核对暂未完成，稍后仍会提醒')));
      }
    } finally {
      _prompting = false;
      final latest = _snapshot;
      if (mounted &&
          widget.autoPromptEnabled &&
          latest != null &&
          latest.reviewSignature != handled &&
          _deferredSignature != latest.reviewSignature &&
          ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_maybePrompt());
      }
    }
  }

  Future<void> _review() async {
    if (_reviewing || _prompting) return;
    setState(() => _reviewing = true);
    try {
      // 点开时重新核对，避免用刚过期或已变化的提示打开旧建议。
      final expectedSequence = _refreshSequence + 1;
      await refresh();
      if (!mounted || expectedSequence != _refreshSequence) return;
      final snapshot = _snapshot;
      if (snapshot == null || !snapshot.showMonthEndReminder) return;
      final review = widget.onReview;
      if (review != null) {
        await review(snapshot);
      } else {
        await MonthlyReportBalanceDialog.show(
          context: context,
          snapshot: snapshot,
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  String _message(MonthlyReportSnapshot snapshot) {
    if (!snapshot.isReady) {
      return snapshot.unavailableReason ?? '本月工时尚未确认，请同步后再核对。';
    }
    final plan = snapshot.plan!;
    final format = MonthlyReportBalance.formatHundredths;
    if (plan.problem == null && plan.suggestions.values.contains(0)) {
      final remainder = plan.remainder > 0
          ? '尚余 ${format(plan.remainder)} 小时尾差，月底不足 0.10 小时的部分可舍弃。'
          : '';
      return '部分未填日期建议为 0.00 小时，请核对已填日志；'
          '无需提交零工时日志。$remainder';
    }
    return switch (plan.problem) {
      MonthlyReportProblem.overReported =>
        '已填报比实际多 ${format(-plan.remainingTotal)} 小时，'
            '未填日期已无法抵扣，请手动编辑已填日志。',
      MonthlyReportProblem.noPendingDates =>
        '已没有未填日期，仍有 ${format(plan.remainingTotal.abs())} 小时差额，'
            '请手动编辑已填日志。',
      MonthlyReportProblem.capacityExceeded =>
        '待分配 ${format(plan.remainingTotal)} 小时超出未填日期可容纳的工时，'
            '请手动核对并编辑已填日志。',
      null =>
        '本月尚余 ${format(plan.remainder)} 小时尾差。'
            '月底可凑整，剩余不足 0.10 小时可舍弃。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final visible =
        snapshot != null &&
        snapshot.showMonthEndReminder &&
        snapshot.fingerprint != _dismissedFingerprint;
    return Column(
      children: [
        if (visible)
          SafeArea(
            bottom: false,
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Card(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                elevation: 0,
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '月底填报核对',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text('${snapshot.month.year}年${snapshot.month.month}月'),
                      const SizedBox(height: 4),
                      Text(_message(snapshot)),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: _reviewing ? null : _review,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('查看建议'),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _dismissedFingerprint = snapshot.fingerprint;
                            }),
                            child: const Text('本次关闭'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // 保持子页面在提醒出现、消失时的身份，避免重新启动首页加载或引导。
        Expanded(
          key: const ValueKey('monthly-report-reminder-content'),
          child: widget.child,
        ),
      ],
    );
  }
}
