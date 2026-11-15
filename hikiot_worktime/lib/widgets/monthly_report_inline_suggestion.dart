import 'dart:async';

import 'package:flutter/material.dart';

import '../models/monthly_report_balance.dart';
import '../services/monthly_report_balance_service.dart';
import '../services/storage_service.dart';

/// 填报工时旁直接展示所选日期的整月分配结果；明确采用后才交给原确认框。
class MonthlyReportInlineSuggestion extends StatefulWidget {
  const MonthlyReportInlineSuggestion({
    super.key,
    required this.date,
    required this.service,
    required this.onAdopt,
    this.synchronize,
    this.adoptedFingerprint,
    this.now,
    this.enabled = true,
    this.onAdoptingChanged,
  });

  final String date;
  final MonthlyReportBalanceService service;
  final void Function(MonthlyReportSnapshot, int) onAdopt;
  final Future<void> Function()? synchronize;
  final String? adoptedFingerprint;
  final DateTime? now;
  final bool enabled;
  final ValueChanged<bool>? onAdoptingChanged;

  @override
  State<MonthlyReportInlineSuggestion> createState() =>
      _MonthlyReportInlineSuggestionState();
}

class _MonthlyReportInlineSuggestionState
    extends State<MonthlyReportInlineSuggestion> {
  MonthlyReportSnapshot? _snapshot;
  String? _message;
  int _sequence = 0;
  bool _loading = true;
  bool _synchronizing = false;
  bool _adopting = false;

  @override
  void initState() {
    super.initState();
    StorageService.bossHoursChanges.addListener(_onHoursChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant MonthlyReportInlineSuggestion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date ||
        oldWidget.service != widget.service ||
        oldWidget.now != widget.now) {
      _snapshot = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    StorageService.bossHoursChanges.removeListener(_onHoursChanged);
    _sequence++;
    super.dispose();
  }

  void _onHoursChanged() => unawaited(_load());

  Future<void> _load() async {
    final sequence = ++_sequence;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final snapshot = await widget.service.load(
        DateTime.parse(widget.date),
        now: widget.now,
      );
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _snapshot = null;
        _loading = false;
        _message = '暂未取得本日建议，请同步考勤与华天工时后刷新';
      });
    }
  }

  Future<void> _refresh() async {
    if (!widget.enabled || _synchronizing || _adopting) return;
    setState(() => _synchronizing = true);
    try {
      await widget.synchronize?.call();
      if (mounted) await _load();
    } catch (_) {
      if (!mounted) return;
      _sequence++;
      setState(() {
        _snapshot = null;
        _loading = false;
        _message = '同步未完成，请稍后刷新建议';
      });
    } finally {
      if (mounted) setState(() => _synchronizing = false);
    }
  }

  Future<void> _adopt() async {
    if (!widget.enabled || _adopting || _loading || _synchronizing) return;
    final snapshot = _snapshot;
    final suggestion =
        snapshot?.isReady == true && snapshot!.plan!.problem == null
        ? snapshot.plan!.suggestions[widget.date]
        : null;
    if (snapshot == null || suggestion == null || suggestion <= 0) return;
    final sequence = _sequence;
    final service = widget.service;
    final date = widget.date;
    setState(() => _adopting = true);
    try {
      widget.onAdoptingChanged?.call(true);
      final current = await service.isCurrent(snapshot);
      if (!mounted) return;
      if (sequence != _sequence ||
          widget.service != service ||
          widget.date != date) {
        return;
      }
      if (!current) {
        setState(() {
          _snapshot = null;
          _message = '月度建议已变化或过期，请刷新后重新采用';
        });
        return;
      }
      widget.onAdopt(snapshot, suggestion);
    } catch (_) {
      if (!mounted ||
          sequence != _sequence ||
          widget.date != date ||
          widget.service != service) {
        return;
      }
      setState(() {
        _snapshot = null;
        _message = '暂未确认月度建议仍有效，请刷新后重试';
      });
    } finally {
      if (mounted) {
        setState(() => _adopting = false);
        widget.onAdoptingChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final plan = snapshot?.isReady == true ? snapshot!.plan : null;
    final suggestion = plan?.problem == null
        ? plan?.suggestions[widget.date]
        : null;
    final adopted =
        snapshot != null && widget.adoptedFingerprint == snapshot.fingerprint;
    final canAdopt =
        widget.enabled &&
        !_loading &&
        !_synchronizing &&
        !_adopting &&
        !adopted &&
        suggestion != null &&
        suggestion > 0;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 10),
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本日填报建议 · ${widget.date}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (_loading)
              const Text('正在核对本日建议…')
            else if (_message != null)
              Text(_message!)
            else if (plan == null)
              Text(snapshot?.unavailableReason ?? '月度数据尚未确认，请刷新建议')
            else ...[
              if (plan.problem != null)
                Text(_problemText(plan))
              else if (suggestion == null)
                const Text('该日期不在未填建议中，请核对所选日期与已填状态')
              else if (suggestion <= 0)
                const Text('本日建议为 0.00 小时，请核对已填日志，无需提交零工时日志')
              else
                Text(
                  '本日建议填报 ${_hours(suggestion)} 小时',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text('本月实际 ${_hours(plan.actualTotal)} 小时'),
                  Text('已填 ${_hours(plan.reportedTotal)} 小时'),
                  Text('待分配 ${_hours(plan.remainingTotal)} 小时'),
                  Text('尾差 ${_hours(plan.remainder)} 小时'),
                ],
              ),
              if (plan.remainder > 0)
                Text(
                  snapshot!.showMonthEndReminder
                      ? '月底核对：剩余不足 0.10 小时的尾差可最终舍弃。'
                      : '尾差先保留，到本月最后一个工作日再核对。',
                ),
            ],
            const SizedBox(height: 6),
            const Text(
              '原始打卡与已填日报保留，采用后仍需确认提交。',
              style: TextStyle(fontSize: 12),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (suggestion != null && suggestion > 0)
                  adopted
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('已采用本日建议'),
                        )
                      : FilledButton.tonal(
                          onPressed: canAdopt ? _adopt : null,
                          child: Text(_adopting ? '正在核对…' : '采用本日建议'),
                        ),
                TextButton(
                  onPressed: !widget.enabled || _synchronizing || _adopting
                      ? null
                      : _refresh,
                  child: Text(_synchronizing ? '同步中…' : '刷新建议'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _hours(int value) =>
      MonthlyReportBalance.formatHundredths(value);

  static String _problemText(MonthlyReportPlan plan) => switch (plan.problem) {
    MonthlyReportProblem.overReported =>
      '已填超过实际 ${_hours(-plan.remainingTotal)} 小时，请手动核对已填日志。',
    MonthlyReportProblem.noPendingDates =>
      '已无未填日期，仍有 ${_hours(plan.remainingTotal.abs())} 小时差额，请手动核对已填日志。',
    MonthlyReportProblem.capacityExceeded =>
      '待分配 ${_hours(plan.remainingTotal)} 小时超出未填日期可分配范围，请手动核对已填日志。',
    null => '',
  };
}
