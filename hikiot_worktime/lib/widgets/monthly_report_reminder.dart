import 'dart:async';

import 'package:flutter/material.dart';

import '../models/monthly_report_balance.dart';
import '../services/monthly_report_balance_service.dart';
import '../services/storage_service.dart';
import 'monthly_report_balance_dialog.dart';

/// 打开或返回 App 时展示月底核对提示；读取缓存，不主动弹窗或提交日报。
class MonthlyReportReminder extends StatefulWidget {
  const MonthlyReportReminder({
    super.key,
    required this.child,
    this.service,
    this.onReview,
  });

  final Widget child;
  final MonthlyReportBalanceService? service;
  final Future<void> Function(MonthlyReportSnapshot snapshot)? onReview;

  @override
  State<MonthlyReportReminder> createState() => MonthlyReportReminderState();
}

class MonthlyReportReminderState extends State<MonthlyReportReminder>
    with WidgetsBindingObserver {
  late MonthlyReportBalanceService _service;
  MonthlyReportSnapshot? _snapshot;
  String? _dismissedFingerprint;
  int _refreshSequence = 0;
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? MonthlyReportBalanceService();
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
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  void _onBossHoursChanged() => unawaited(refresh());

  /// 主页面完成月度考勤刷新后调用，保持提醒与实际缓存一致。
  Future<void> refresh() async {
    final sequence = ++_refreshSequence;
    try {
      final snapshot = await _service.load(_service.now);
      if (!mounted || sequence != _refreshSequence) return;
      setState(() => _snapshot = snapshot);
    } catch (_) {
      // 正常未知状态由服务层明确返回；意外读取异常不阻塞主页面。
    }
  }

  Future<void> _review() async {
    if (_reviewing) return;
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
