import 'package:flutter/material.dart';

import '../models/monthly_report_balance.dart';
import '../services/monthly_report_balance_service.dart';
import '../utils/date_helper.dart';

/// 月度填报建议只作预览；返回的整数仍需调用方复核并交给原提交确认流程。
class MonthlyReportBalanceDialog {
  MonthlyReportBalanceDialog._();

  /// 只有明确采用所选日期时才返回该日建议，单位为 0.01 小时。
  static Future<int?> show({
    required BuildContext context,
    required MonthlyReportSnapshot snapshot,
    String? selectedDate,
  }) => showDialog<int>(
    context: context,
    builder: (context) => _MonthlyReportBalanceDialogBody(
      snapshot: snapshot,
      selectedDate: selectedDate,
    ),
  );
}

class _MonthlyReportBalanceDialogBody extends StatelessWidget {
  const _MonthlyReportBalanceDialogBody({
    required this.snapshot,
    this.selectedDate,
  });

  final MonthlyReportSnapshot snapshot;
  final String? selectedDate;

  @override
  Widget build(BuildContext context) {
    final plan = snapshot.plan;
    final ready = plan != null && snapshot.unavailableReason == null;
    final selected = ready && plan.problem == null
        ? plan.suggestions[selectedDate]
        : null;
    final canAdopt = selectedDate != null && selected != null && selected > 0;

    return AlertDialog(
      title: const Text('月度填报工时建议'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${DateHelper.formatMonth(snapshot.month)} · '
                '截至 ${DateHelper.formatDate(snapshot.asOf)}',
              ),
              const SizedBox(height: 8),
              Text(
                '本月最后工作日：${DateHelper.formatDate(snapshot.lastWorkday)}'
                '（含调休）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Text('已填日报的多报、少报计入待填预算，未填日期按 0.10 小时分配。'),
              const SizedBox(height: 12),
              if (!ready)
                _notice(
                  context,
                  snapshot.unavailableReason ?? '月度数据尚未确认，请同步考勤与华天工时后再生成建议。',
                )
              else ...[
                _total('实际工作总工时', plan.actualTotal),
                _total('已填报总工时', plan.reportedTotal),
                _total('未填日期可分配工时', plan.remainingTotal),
                if (plan.problem == null)
                  _total(
                    '本次建议合计',
                    plan.suggestions.values.fold<int>(
                      0,
                      (sum, value) => sum + value,
                    ),
                  )
                else
                  const Text('本次建议：需手工核对'),
                _total('尾差', plan.remainder),
                const SizedBox(height: 10),
                if (plan.problem != null)
                  _notice(context, _problemText(plan.problem!))
                else if (plan.remainder > 0)
                  _notice(
                    context,
                    snapshot.showMonthEndReminder
                        ? '已到月底核对时间。尾差 '
                              '${_hours(plan.remainder)} 小时不足 0.10 小时，'
                              '建议最终舍弃。'
                        : '尾差 ${_hours(plan.remainder)} 小时先保留，'
                              '到本月最后一个工作日再核对；当前建议未计入这部分。',
                  )
                else
                  const Text('本次建议没有尾差。'),
                if (plan.pendingActual.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('未填日期', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final date in plan.pendingActual.keys.toList()..sort())
                    _day(context, date, plan),
                ],
                if (selectedDate != null &&
                    selected == null &&
                    plan.problem == null)
                  _notice(context, '所选日期不在本次待填建议中，请核对日期与填报状态。'),
                if (selected == 0)
                  _notice(context, '所选日期建议为 0.00 小时，请核对分配结果；无需提交零工时日志。'),
              ],
              const SizedBox(height: 12),
              Text(
                '建议用于华天填报，原始打卡与已填日报保留。采用建议后，仍需在原提交页面核对并确认。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (canAdopt)
          FilledButton(
            onPressed: () => Navigator.pop(context, selected),
            child: Text('采用 $selectedDate 建议'),
          ),
      ],
    );
  }

  Widget _total(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Wrap(
      spacing: 12,
      runSpacing: 2,
      children: [Text(label), Text('${_hours(value)} 小时')],
    ),
  );

  Widget _day(BuildContext context, String date, MonthlyReportPlan plan) {
    final selected = date == selectedDate;
    final suggestion = plan.suggestions[date];
    return Container(
      key: ValueKey('monthly-balance-$date'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(selected ? '当前日期 · $date' : date),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('原工时 ${_hours(plan.pendingActual[date]!)}'),
              const Text('→'),
              Text(suggestion == null ? '待手工核对' : '建议 ${_hours(suggestion)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  static String _hours(int value) =>
      MonthlyReportBalance.formatHundredths(value);

  static String _problemText(MonthlyReportProblem problem) => switch (problem) {
    MonthlyReportProblem.overReported =>
      '已填总量超过实际工作总量，未填日期无法继续抵扣。请核对并手动编辑已填日报。',
    MonthlyReportProblem.noPendingDates => '本月已没有可分配的未填日期，但仍存在差额。请核对并手动编辑已填日报。',
    MonthlyReportProblem.capacityExceeded =>
      '剩余工时超出未填日期的可分配范围。请核对原始工时并手动编辑已填日报。',
  };
}
