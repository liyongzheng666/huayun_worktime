import 'package:flutter/material.dart';

import '../models/today_wrap_up.dart';
import '../utils/date_helper.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_time_calculator.dart';

/// 工作台只展示页面已确认的数据，操作仍交由原页面处理。
class IosWorkbench extends StatelessWidget {
  const IosWorkbench({
    super.key,
    required this.selectedDate,
    required this.hours,
    required this.onRefresh,
    required this.onSelectDate,
    required this.onAction,
    required this.onEditAttendance,
    this.monthHours,
    this.attendanceData,
    this.summary,
    this.entry,
    this.updatedAt,
    this.today,
    this.isRefreshing = false,
    this.loadFailed = false,
    this.attendanceFailed = false,
  });

  final DateTime selectedDate;
  final double hours;
  final double? monthHours;
  final Map<String, dynamic>? attendanceData;
  final TodayWrapUpSummary? summary;
  final WorkLogEntry? entry;
  final DateTime? updatedAt;
  final DateTime? today;
  final bool isRefreshing;
  final bool loadFailed;
  final bool attendanceFailed;
  final VoidCallback onRefresh;
  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<TodayWrapUpAction> onAction;
  final VoidCallback onEditAttendance;

  String _time(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : '待确认';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = summary;
    final log = entry;
    final items = status == null
        ? const [
            TodayWrapUpItem(
              label: '打卡记录待确认',
              detail: '刷新后查看今天的记录',
              status: TodayWrapUpItemStatus.unknown,
            ),
            TodayWrapUpItem(
              label: '日志素材待确认',
              detail: '正在确认今天的内容',
              status: TodayWrapUpItemStatus.unknown,
            ),
            TodayWrapUpItem(
              label: '日志提交状态待确认',
              detail: '查清楚后再决定下一步',
              status: TodayWrapUpItemStatus.unknown,
            ),
          ]
        : [status.attendance, status.csv, status.submission];
    final completed = items
        .where((item) => item.status == TodayWrapUpItemStatus.complete)
        .length;
    final updated = updatedAt;
    final updateText = isRefreshing
        ? '正在更新…'
        : loadFailed
        ? '更新未完成'
        : updated == null
        ? '尚未同步'
        : '更新于 ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('ios-workbench-scroll'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(
                            Icons.view_week_outlined,
                            size: 17,
                            color: colors.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('华云工时', style: theme.textTheme.titleSmall),
                      ),
                      Flexible(
                        child: Text(
                          updateText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新今日状态',
                        onPressed: isRefreshing ? null : onRefresh,
                        icon: isRefreshing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 19),
                      ),
                    ],
                  ),
                  Divider(color: colors.outlineVariant, height: 1),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Text(
                        '今日工作台',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${selectedDate.year} 年 ${selectedDate.month} 月',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _WeekStrip(
                    selectedDate: selectedDate,
                    today: today ?? DateTime.now(),
                    onSelectDate: onSelectDate,
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _Metric(
                                  label: '今日工时',
                                  value:
                                      attendanceFailed || attendanceData == null
                                      ? null
                                      : hours,
                                ),
                              ),
                              VerticalDivider(
                                width: 1,
                                color: colors.outlineVariant,
                              ),
                              Expanded(
                                child: _Metric(
                                  label: '本月累计 · 缓存',
                                  value: monthHours,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: colors.outlineVariant),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '上班  ${_time(attendanceData?['checkInTime'])}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '下班  ${_time(attendanceData?['checkOutTime'])}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: isRefreshing ? null : onEditAttendance,
                      child: const Text(
                        '核对工时与类型',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  if (loadFailed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '暂时没查清楚，点右上角刷新后再确认。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Text(
                        '收尾清单',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '$completed / 3 已确认完成',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final item in items) _ChecklistRow(item: item),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.work_outline_rounded,
                              size: 15,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                log == null || log.projectName.isEmpty
                                    ? '今日日志素材'
                                    : log.projectName,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          log == null ? '留一点记录，让今天有迹可循' : log.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          log == null ? '导入今天的日志素材后，在这里预览内容。' : log.content,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            key: const ValueKey('ios-workbench-footer'),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final largeText =
                    MediaQuery.textScalerOf(context).scale(12) > 18;
                final button = FilledButton(
                  key: const ValueKey('ios-workbench-action'),
                  onPressed: isRefreshing
                      ? null
                      : () => status == null
                            ? onRefresh()
                            : onAction(status.primaryAction),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    isRefreshing ? '正在更新…' : status?.actionLabel ?? '刷新确认',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                );
                final hint = Text(
                  status?.title ?? '先确认一下今天的状态',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                );
                if (largeText || constraints.maxWidth < 280) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [hint, const SizedBox(height: 8), button],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: hint),
                    const SizedBox(width: 12),
                    Flexible(child: button),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, this.value});
  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hours = value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  hours == null || !hours.isFinite
                      ? '—'
                      : WorkTimeCalculator.formatHours(hours),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '小时',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.selectedDate,
    required this.today,
    required this.onSelectDate,
  });
  final DateTime selectedDate;
  final DateTime today;
  final ValueChanged<DateTime> onSelectDate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final monday = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day - selectedDate.weekday + 1,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final width = (constraints.maxWidth / 7).clamp(
          40.0 * scale,
          double.infinity,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(7, (index) {
              final date = DateTime(
                monday.year,
                monday.month,
                monday.day + index,
              );
              final selected =
                  DateHelper.formatDate(date) ==
                  DateHelper.formatDate(selectedDate);
              final future = date.isAfter(
                DateTime(today.year, today.month, today.day),
              );
              return SizedBox(
                width: width,
                child: Semantics(
                  selected: selected,
                  label: '${date.month}月${date.day}日',
                  child: TextButton(
                    key: ValueKey(
                      'workbench-date-${DateHelper.formatDate(date)}',
                    ),
                    onPressed: future ? null : () => onSelectDate(date),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      minimumSize: const Size(40, 48),
                      foregroundColor: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      disabledForegroundColor: colors.onSurfaceVariant
                          .withValues(alpha: 0.4),
                      backgroundColor: selected
                          ? colors.surfaceContainerLow
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: selected
                            ? BorderSide(color: colors.outlineVariant)
                            : BorderSide.none,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          const ['一', '二', '三', '四', '五', '六', '日'][index],
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${date.day}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.item});
  final TodayWrapUpItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final icon = switch (item.status) {
      TodayWrapUpItemStatus.complete => Icons.check_circle_outline_rounded,
      TodayWrapUpItemStatus.pending => Icons.radio_button_unchecked_rounded,
      TodayWrapUpItemStatus.unknown => Icons.help_outline_rounded,
      TodayWrapUpItemStatus.neutral => Icons.remove_circle_outline_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: 18,
              color: item.status == TodayWrapUpItemStatus.complete
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.3,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
