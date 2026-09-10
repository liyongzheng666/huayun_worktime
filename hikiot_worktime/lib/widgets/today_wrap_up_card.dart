import 'package:flutter/material.dart';

import '../models/today_wrap_up.dart';

/// 今日状态只由汇总模型决定；卡片不会查询网络或直接提交日志。
class TodayWrapUpCard extends StatelessWidget {
  const TodayWrapUpCard({
    super.key,
    required this.summary,
    required this.onAction,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final TodayWrapUpSummary summary;
  final ValueChanged<TodayWrapUpAction> onAction;
  final VoidCallback? onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Color.alphaBlend(
        colors.primary.withValues(alpha: 0.055),
        colors.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '今日收尾',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (onRefresh != null)
                  IconButton(
                    tooltip: isRefreshing ? '正在更新今日状态' : '刷新今日状态',
                    onPressed: isRefreshing ? null : onRefresh,
                    icon: isRefreshing
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.primary,
                            ),
                          )
                        : Icon(Icons.refresh_rounded, color: colors.primary),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              summary.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              summary.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            for (final item in [
              summary.attendance,
              summary.csv,
              summary.submission,
            ])
              _StatusRow(item: item),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: isRefreshing
                  ? null
                  : () => onAction(summary.primaryAction),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                isRefreshing ? '正在更新…' : summary.actionLabel,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.item});

  final TodayWrapUpItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final (icon, color) = switch (item.status) {
      TodayWrapUpItemStatus.complete => (
        Icons.check_circle_rounded,
        isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      ),
      TodayWrapUpItemStatus.pending => (Icons.schedule_rounded, colors.primary),
      TodayWrapUpItemStatus.unknown => (
        Icons.help_outline_rounded,
        colors.onSurfaceVariant,
      ),
      TodayWrapUpItemStatus.neutral => (
        Icons.remove_circle_outline_rounded,
        colors.onSurfaceVariant,
      ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${item.label}  ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: item.detail,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
