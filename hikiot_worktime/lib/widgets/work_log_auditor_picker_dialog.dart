import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/work_log_submit_service.dart';
import '../utils/work_log_auditor_lookup.dart';

/// 用户在审核人选择框里的选择
class AuditorPickResult {
  const AuditorPickResult({required this.confirmed, this.auditor});

  final bool confirmed;
  final BossAuditor? auditor;
}

/// 从抓包里认出的候选中挑出工作日志的审核人
///
/// **为什么让用户选而不是自动认**：审核人是个人设置，不是项目属性，也不在
/// 项目清单里。自动识别已经在真实使用中失败过两次——设置项在响应里以哪种
/// 形状出现，我们始终没有实测证据，再猜下去只是换个姿势碰运气。
///
/// 而抓包里的 `USERINFO_` 大多带着姓名：**APP 分不清哪个是审核人、哪个是
/// 用户自己，但用户一眼就能认出来**。这和项目选择框是同一个思路——别猜，
/// 把候选全列出来交给用户定。
///
/// **填错审核人的后果是日志提交给错误的审批人**，所以这里同样不预选「看着
/// 像的那个」：只有来自个人设置的候选才预选，其余一律要用户自己点。
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
                      '没能从 BOSS 的抓包里认出任何审核人。\n'
                      '请到「我的工作日志」点开一个已填过的日期，'
                      '让页面把审核人信息发出来，再回来提交；'
                      '或在「提交配置」里手工填审核人 ID。',
                    )
                  else ...[
                    Text(
                      '扫到 ${auditors.length} 个候选。'
                      'APP 分不清哪个是审核人、哪个是你自己，请你确认：',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                    const SizedBox(height: 8),
                    ...auditors.map(
                      (a) => _candidate(
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
                        AuditorPickResult(
                          confirmed: true,
                          auditor: selected,
                        ),
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
  /// **不落绑定**：审核人是个人设置，跟着人走而不是跟着 CSV 项目走；
  /// 由调用方在项目也定下来之后统一绑定，免得存下一份只有审核人的残缺配置。
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
  /// 只认两种：当前配置里已有的那个，或者来自个人设置的那个（权威出处）。
  /// **不拿「第一个」当默认**——排序靠前不代表就是审核人。
  static BossAuditor? _initialSelection(
    List<BossAuditor> auditors,
    String currentId,
  ) {
    for (final a in auditors) {
      if (a.id == currentId && currentId.isNotEmpty) return a;
    }
    for (final a in auditors) {
      if (a.source == BossAuditorSource.setting) return a;
    }
    return null;
  }

  static Widget _candidate({
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
          color: selected ? AppColors.infoLight : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.info : Colors.grey.shade300,
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
              color: selected ? AppColors.info : Colors.grey,
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
                      color: auditor.name.isEmpty ? Colors.grey : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    auditor.source.label,
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                  SelectableText(
                    auditor.id,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.grey,
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

  static Widget _warning(String text) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warningLight,
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
