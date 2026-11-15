import 'package:flutter/material.dart';

import '../models/monthly_report_balance.dart';
import '../services/monthly_report_balance_service.dart';
import '../utils/date_helper.dart';

/// 月底明确核对实际总额与华天已填总额，只返回用户已核对的有效快照。
class MonthEndReportReviewDialog {
  MonthEndReportReviewDialog._();

  static Future<MonthlyReportSnapshot?> show({
    required BuildContext context,
    required MonthlyReportSnapshot snapshot,
    Future<MonthlyReportSnapshot> Function()? onRefresh,
    Future<bool> Function(MonthlyReportSnapshot)? validate,
  }) => showDialog<MonthlyReportSnapshot>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MonthEndReportReview(
      snapshot: snapshot,
      onRefresh: onRefresh,
      validate: validate,
    ),
  );
}

class _MonthEndReportReview extends StatefulWidget {
  const _MonthEndReportReview({
    required this.snapshot,
    this.onRefresh,
    this.validate,
  });

  final MonthlyReportSnapshot snapshot;
  final Future<MonthlyReportSnapshot> Function()? onRefresh;
  final Future<bool> Function(MonthlyReportSnapshot)? validate;

  @override
  State<_MonthEndReportReview> createState() => _MonthEndReportReviewState();
}

class _MonthEndReportReviewState extends State<_MonthEndReportReview> {
  late MonthlyReportSnapshot _snapshot;
  String? _unavailableMessage;
  bool _busy = false;
  bool _refreshing = false;
  int _sequence = 0;

  bool get _ready => _snapshot.isReady && _unavailableMessage == null;
  bool get _active => mounted && ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.snapshot;
  }

  @override
  void dispose() {
    _sequence++;
    super.dispose();
  }

  void _later() {
    _sequence++;
    Navigator.pop(context);
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefresh;
    if (_busy || refresh == null) return;
    final sequence = ++_sequence;
    setState(() {
      _busy = true;
      _refreshing = true;
    });
    try {
      final snapshot = await refresh();
      if (!_active || sequence != _sequence) return;
      setState(() {
        _snapshot = snapshot;
        _unavailableMessage = null;
      });
    } catch (_) {
      if (!_active || sequence != _sequence) return;
      setState(() {
        _unavailableMessage = '刷新未完成，请同步考勤与华天数据后重试';
      });
    } finally {
      if (_active && sequence == _sequence) {
        setState(() {
          _busy = false;
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _reviewed() async {
    if (_busy || !_ready) return;
    final sequence = ++_sequence;
    final snapshot = _snapshot;
    setState(() {
      _busy = true;
      _refreshing = false;
    });
    try {
      final validate = widget.validate;
      final valid = validate == null || await validate(snapshot);
      if (!_active || sequence != _sequence) return;
      if (!valid) {
        setState(() {
          _unavailableMessage = '核对数据已变化或过期，请刷新后再确认';
        });
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, snapshot);
    } catch (_) {
      if (!_active || sequence != _sequence) return;
      setState(() {
        _unavailableMessage = '暂未确认核对数据仍有效，请刷新后重试';
      });
    } finally {
      if (_active && sequence == _sequence) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _ready ? _snapshot.plan : null;
    return AlertDialog(
      title: const Text('本月填报差额核对'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${DateHelper.formatMonth(_snapshot.month)} 月度核对'),
              const SizedBox(height: 6),
              Text(
                '本月最后工作日：${DateHelper.formatDate(_snapshot.lastWorkday)}（含调休）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              const Text('基于已同步考勤和华天数据'),
              const SizedBox(height: 14),
              _metric('应填写（实际工时）', _hours(plan?.actualTotal)),
              _metric('华天已填写', _hours(plan?.reportedTotal)),
              _metric(
                '差额（应填－已填）',
                plan == null ? '待确认' : _difference(plan.remainingTotal),
                emphasize: true,
              ),
              const SizedBox(height: 12),
              if (plan == null)
                Text(
                  _unavailableMessage ??
                      _snapshot.unavailableReason ??
                      '月度工时尚未完整确认，请同步考勤与华天工时后核对',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                Text(_nextAction(plan)),
              const SizedBox(height: 12),
              Text(
                '请核对原始考勤与华天记录。此处只确认查看结果，工时调整仍在原填报流程中操作。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _later, child: const Text('稍后核对')),
        if (widget.onRefresh != null)
          TextButton(
            onPressed: _busy ? null : _refresh,
            child: Text(_refreshing ? '正在刷新…' : '刷新核对'),
          ),
        FilledButton(
          onPressed: _busy || !_ready ? null : _reviewed,
          child: Text(_busy && !_refreshing ? '正在核对…' : '我已核对'),
        ),
      ],
    );
  }

  Widget _metric(String label, String value, {bool emphasize = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Wrap(
          spacing: 14,
          runSpacing: 3,
          children: [
            Text(label),
            Text(
              value,
              style: emphasize
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          ],
        ),
      );

  static String _hours(int? value) => value == null
      ? '待确认'
      : '${MonthlyReportBalance.formatHundredths(value)} 小时';

  static String _difference(int value) {
    if (value == 0) return '一致，差额 0.00 小时';
    return '${value > 0 ? '少填' : '多填'} '
        '${MonthlyReportBalance.formatHundredths(value.abs())} 小时';
  }

  static String _nextAction(MonthlyReportPlan plan) {
    if (plan.remainingTotal < 0) {
      return '已填写超过实际工时，请核对并手动编辑已填日报。';
    }
    if (plan.remainingTotal > 0 && plan.pendingActual.isEmpty) {
      return '已没有未填日期，仍存在差额，请核对并手动编辑已填日报。';
    }
    if (plan.problem == MonthlyReportProblem.capacityExceeded) {
      return '剩余工时无法在未填日期内分配，请核对并手动编辑已填日报。';
    }
    if (plan.remainingTotal > 0) {
      return '本月还有少填工时，请核对未填日期及已填日报，再按实际情况补填。';
    }
    return '本月已填与应填总量一致，请继续核对每日记录是否准确。';
  }
}
