import 'package:flutter/material.dart';

import '../core/theme/legacy_theme_colors.dart';
import '../core/theme/theme.dart';
import '../services/work_log_submit_service.dart';
import '../utils/work_log_auditor_lookup.dart';

/// 用户在审核人选择框里的选择
class AuditorPickResult {
  const AuditorPickResult({required this.confirmed, this.auditor});

  final bool confirmed;
  final BossAuditor? auditor;
}

/// 从当前项目的审核人接口、个人设置和历史数据里选择审核人。
///
/// 同一用户在不同项目可以有不同审核人。当前项目接口的唯一候选可以作为
/// 默认值；只有历史抓包等候选时，仍由用户核对姓名，避免误选自己或其他人员。
class WorkLogAuditorPickerDialog {
  WorkLogAuditorPickerDialog._();

  static Future<AuditorPickResult> show({
    required BuildContext context,
    required List<BossAuditor> auditors,
    String currentId = '',
  }) async {
    var selected = _initialSelection(auditors, currentId);

    final result = await showDialog<AuditorPickResult>(
      context: context,
      // 发给错误的审批人不是能糊弄过去的事，必须是一次明确的选择
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('选择日志审核人'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (auditors.isEmpty)
                    _warning(
                      context,
                      '没能查到当前项目的审核人。\n'
                      '请在 BOSS 核对该项目的审核人设置；'
                      '也可打开这个项目的历史日志后重试，'
                      '或在「提交配置」里手工填审核人 ID。',
                    )
                  else ...[
                    Text(
                      '查到 ${auditors.length} 个候选。'
                      '请根据姓名和来源确认当前项目的审核人：',
                      style: TextStyle(
                        fontSize: 12,
                        color: LegacyThemeColors.muted(
                          context,
                          Colors.grey[700]!,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...auditors.map(
                      (a) => _candidate(
                        context: context,
                        auditor: a,
                        selected: selected?.id == a.id,
                        current: a.id == currentId && currentId.isNotEmpty,
                        onTap: () => setDialogState(() => selected = a),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '选错会把日志提交给错误的审批人，确认前请核对姓名。',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.warningDark,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                const AuditorPickResult(confirmed: false),
              ),
              child: Text(auditors.isEmpty ? '知道了' : '都不是'),
            ),
            if (auditors.isNotEmpty)
              FilledButton(
                // 没选中就不放行：列表摆在这里却允许「什么都没选就确定」，
                // 等于又给了一条静默走错的路
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        AuditorPickResult(confirmed: true, auditor: selected),
                      ),
                child: const Text('就用选中的'),
              ),
          ],
        ),
      ),
    );

    return result ?? const AuditorPickResult(confirmed: false);
  }

  /// 弹选择框 → 按选择重建配置。返回新配置；放弃时返回 null。
  ///
  /// 不落绑定：由调用方在项目和审核人都定下来之后统一保存。
  static Future<Map<String, String>?> pick({
    required BuildContext context,
    required Map<String, String> constants,
    required List<BossAuditor> auditors,
  }) async {
    final choice = await show(
      context: context,
      auditors: auditors,
      currentId: constants['auditor'] ?? '',
    );
    if (!choice.confirmed || choice.auditor == null) return null;

    return WorkLogSubmitService.constantsForAuditor(constants, choice.auditor!);
  }

  /// 默认选中哪一个。
  ///
  /// 已确认的人员优先，否则使用当前项目接口或个人设置的唯一候选。
  /// 多个候选不按排序预选，交给用户确认。
  static BossAuditor? _initialSelection(
    List<BossAuditor> auditors,
    String currentId,
  ) {
    for (final a in auditors) {
      if (a.id == currentId && currentId.isNotEmpty) return a;
    }
    return WorkLogSubmitService.preferredAuditor(auditors);
  }

  static Widget _candidate({
    required BuildContext context,
    required BossAuditor auditor,
    required bool selected,
    required bool current,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? LegacyThemeColors.primaryContainer(context, AppColors.infoLight)
              : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? LegacyThemeColors.primary(context, AppColors.info)
                : LegacyThemeColors.border(context, Colors.grey.shade300),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected
                  ? LegacyThemeColors.primary(context, AppColors.info)
                  : LegacyThemeColors.muted(context, Colors.grey),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // 没扫到姓名的照直说，不要显示成空白让人以为是渲染问题
                    auditor.name.isEmpty ? '（没扫到姓名）' : auditor.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: auditor.name.isEmpty
                          ? LegacyThemeColors.muted(context, Colors.grey)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    auditor.source.label,
                    style: TextStyle(
                      fontSize: 10,
                      color: LegacyThemeColors.muted(
                        context,
                        Colors.grey[600]!,
                      ),
                    ),
                  ),
                  SelectableText(
                    auditor.id,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: LegacyThemeColors.muted(context, Colors.grey),
                    ),
                  ),
                  if (current)
                    Text(
                      '当前用的就是他',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.warningDark,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _warning(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: LegacyThemeColors.panel(context, AppColors.warningLight),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: AppColors.warningDark),
      ),
    );
  }
}
