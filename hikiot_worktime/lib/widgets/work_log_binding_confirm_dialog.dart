import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../utils/project_name_matcher.dart';
import '../utils/work_log_project_list_lookup.dart';

/// 绑定确认的结果
class BindingChoice {
  const BindingChoice({required this.confirmed, this.project});

  /// 用户是否确认了一个项目
  final bool confirmed;

  /// 用户改选的项目；为 null 表示沿用自动学到的那份配置
  final BossProject? project;
}

/// CSV 项目名与 BOSS 项目名对不上时的绑定确认框
///
/// 决定工时记到哪个项目的是 `PROJECTID`，不是项目名。名字对不上说明 APP
/// **没能**在 BOSS 的历史日志里找到同名项目，只能退而取到一条记录——用户
/// 在 BOSS 做过多个项目时，这一条完全可能属于别的项目，且提交不会报错。
///
/// 因此这里必须把项目 ID 摆出来让用户核对，而不是替他猜；确认后记住绑定
/// 关系，同一个 CSV 项目名之后不再询问，也不再每次重学。
///
/// **扫到项目清单时给候选列表**（按名称接近程度排序），用户可以直接改选；
/// 排序只用来决定谁排前面，**不代表 APP 认定它就是对的**。扫不到清单时
/// 退回到「是 / 不是」的单项确认，不比以前差。
class WorkLogBindingConfirmDialog {
  WorkLogBindingConfirmDialog._();

  static Future<BindingChoice> show({
    required BuildContext context,
    required String csvProjectName,
    required Map<String, String> constants,
    List<BossProject> projects = const [],
  }) async {
    final learnedId = constants['projectId'] ?? '';
    final matches = ProjectNameMatcher.rank(projects, csvProjectName);

    // 默认选中自动学到的那个；它不在清单里（清单没扫全）时才退而选最接近的
    var selected = matches
        .where((m) => m.project.id == learnedId)
        .firstOrNull
        ?.project;
    selected ??= matches.isEmpty ? null : matches.first.project;

    final result = await showDialog<BindingChoice>(
      context: context,
      // 绑错项目的后果是工时记到别人名下，不能让用户点外面糊弄过去
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('项目名对不上'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _nameRow('CSV 里写的', csvProjectName),
                  if (matches.isEmpty) ...[
                    _nameRow('BOSS 里学到的', constants['projectName'] ?? ''),
                    const SizedBox(height: 10),
                    _idRow('项目 ID', learnedId),
                    _idRow('审核人', _auditorLabel(constants)),
                    const SizedBox(height: 12),
                    _warning(
                      '没能在 BOSS 的历史日志里找到与 CSV 同名的项目，'
                      '上面这个是自动选中的一条。\n'
                      '如果你在 BOSS 做过多个项目，它可能不是你要的那个——'
                      '确认前请核对项目 ID。',
                    ),
                  ] else ...[
                    const SizedBox(height: 10),
                    Text(
                      '从 BOSS 扫到 ${matches.length} 个项目，'
                      '按名称接近程度排列。请选出正确的那个：',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                    const SizedBox(height: 6),
                    // 排序只决定顺序，不代表 APP 认定谁是对的，
                    // 因此不预先替用户下结论式地标注「推荐」
                    ...matches.map(
                      (m) => _candidate(
                        match: m,
                        selected: selected?.id == m.project.id,
                        learned: m.project.id == learnedId,
                        onTap: () =>
                            setDialogState(() => selected = m.project),
                      ),
                    ),
                  ],
                  // 改选别的项目就丢掉了随原项目学到的审核人。
                  // 审核人填错会把日志提交给错误的审批人，必须先说清楚
                  if (matches.isNotEmpty && selected?.id != learnedId)
                    _warning(
                      '你选的不是自动学到的那个项目。'
                      '审核人仍沿用当前学到的「${_auditorLabel(constants)}」，'
                      '请在下一步的提交确认框里核对。',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '确认后会记住这个对应关系，之后不再询问。',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                const BindingChoice(confirmed: false),
              ),
              child: Text(matches.isEmpty ? '不是同一个' : '都不是'),
            ),
            FilledButton(
              onPressed: matches.isNotEmpty && selected == null
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      BindingChoice(
                        confirmed: true,
                        // 选的就是自动学到的那个时不必回传，避免调用方
                        // 拿一份缺少审核人的配置去覆盖完整的那份
                        project: selected?.id == learnedId ? null : selected,
                      ),
                    ),
              child: Text(matches.isEmpty ? '是同一个项目' : '就用选中的'),
            ),
          ],
        ),
      ),
    );

    return result ?? const BindingChoice(confirmed: false);
  }

  static String _auditorLabel(Map<String, String> constants) =>
      constants['auditorName']?.isNotEmpty == true
      ? constants['auditorName']!
      : '（未知，仅有 ID）';

  /// 一个候选项目。
  ///
  /// 匹配档位用文字说明而不是打分：分数会被读成「有多大把握」，
  /// 而这件事本质上不是概率——是不是同一个项目只有用户知道。
  static Widget _candidate({
    required ProjectMatch match,
    required bool selected,
    required bool learned,
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
                    match.project.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    match.level.label,
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                  SelectableText(
                    match.project.id,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.grey,
                    ),
                  ),
                  // 这一条就是自动学到、审核人等配置所属的那个项目；
                  // 改选别的会连带丢掉审核人，必须说清楚
                  if (learned)
                    Text(
                      '当前自动学到的就是它（含审核人配置）',
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

  static Widget _nameRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            value.isEmpty ? '（空）' : value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// ID 用等宽小字：它是拿来逐字核对的，不是拿来读的。
  static Widget _idRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '（空）' : value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
