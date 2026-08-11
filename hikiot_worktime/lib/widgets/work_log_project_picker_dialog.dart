import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/work_log_submit_service.dart';
import '../utils/project_name_matcher.dart';
import '../utils/work_log_project_list_lookup.dart';

/// 弹这个框是为了什么
enum ProjectPickPurpose {
  /// CSV 项目名在 BOSS 里没有同名项目，提交前必须先定下来
  confirm,

  /// 用户在提交确认框里主动点了「改选」
  change,
}

/// 用户在选择框里的选择
class ProjectPickResult {
  const ProjectPickResult({required this.confirmed, this.project});

  /// 用户是否定下了一个项目
  final bool confirmed;

  /// 用户选中的项目；为 null 表示沿用当前那份配置
  final BossProject? project;
}

/// 从 BOSS 的全量项目清单里挑出正确的那个
///
/// **决定工时记到哪个项目的是 `PROJECTID`，不是项目名。** 名字对不上时 APP
/// 没有任何可靠办法替用户判断——「XX平台」和「XX平台(2)」既可能是同一项目的
/// 二期，也可能是两个独立项目。让算法替他判，等于把「静默绑错项目」换身衣服
/// 重来一遍，而且更难被发现，因为它看起来有理有据。所以这里只做两件事：
/// 把 BOSS 上真实存在的项目全都摆出来，按名称接近程度排个顺序。**排序不代表
/// APP 认定谁是对的。**
///
/// 项目清单登录后就能全量扫到（首页自动发 `GetMyJoinProjectGrid`），因此这个框
/// 不依赖用户在 BOSS 里填过日志；扫不到清单时才退回「是 / 不是」的单项确认。
class WorkLogProjectPickerDialog {
  WorkLogProjectPickerDialog._();

  /// 超过这个数量就显示搜索框。太少时搜索框只是碍事。
  static const int searchThreshold = 8;

  /// 弹选择框 → 按用户的选择重建配置 → 落绑定。返回新配置，放弃时返回 null。
  ///
  /// 收在这里是因为后台提交和网页内提交都要走这一串，而「选中项目 → 换 ID →
  /// 记住绑定」一旦两边写法不一致，症状就是**某一条路径上项目绑错却不报错**。
  /// 本项目已经在 `findPara` 上吃过一模一样的亏（踩坑记录 2.7、3.11）。
  static Future<Map<String, String>?> pickAndBind({
    required BuildContext context,
    required String csvProjectName,
    required Map<String, String> constants,
    required List<BossProject> projects,
    ProjectPickPurpose purpose = ProjectPickPurpose.confirm,
  }) async {
    final choice = await show(
      context: context,
      csvProjectName: csvProjectName,
      constants: constants,
      projects: projects,
      purpose: purpose,
    );
    if (!choice.confirmed) return null;

    final chosen = choice.project == null
        ? constants
        : WorkLogSubmitService.constantsForProject(constants, choice.project!);

    // 确认之后才落绑定：用户放弃时不留下一个错误的对应关系
    return WorkLogSubmitService.bindConstants(chosen, csvProjectName);
  }

  static Future<ProjectPickResult> show({
    required BuildContext context,
    required String csvProjectName,
    required Map<String, String> constants,
    List<BossProject> projects = const [],
    ProjectPickPurpose purpose = ProjectPickPurpose.confirm,
  }) async {
    final currentId = constants['projectId'] ?? '';
    final matches = ProjectNameMatcher.rank(projects, csvProjectName);

    var selected = _initialSelection(matches, currentId);
    final searchController = TextEditingController();

    final result = await showDialog<ProjectPickResult>(
      context: context,
      // 绑错项目的后果是工时记到别的项目名下，不能让用户点外面糊弄过去。
      // 主动改选是他自己发起的，点外面取消很自然，就不必拦。
      barrierDismissible: purpose == ProjectPickPurpose.change,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final keyword = searchController.text.trim();
          final visible = _filter(matches, keyword);

          return AlertDialog(
            title: Text(
              purpose == ProjectPickPurpose.change ? '改选项目' : '选择 BOSS 里的项目',
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _nameRow('CSV 里写的', csvProjectName),
                    if (matches.isEmpty)
                      ..._withoutList(constants, currentId)
                    else ...[
                      const SizedBox(height: 4),
                      Text(
                        purpose == ProjectPickPurpose.change
                            ? '从 BOSS 扫到 ${matches.length} 个项目，'
                                  '按与 CSV 名称的接近程度排列：'
                            : 'BOSS 里没有与它同名的项目。'
                                  '已扫到 ${matches.length} 个项目，'
                                  '按名称接近程度排列，请选出正确的那个：',
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                      if (matches.length > searchThreshold)
                        _searchField(
                          controller: searchController,
                          onChanged: () => setDialogState(() {}),
                        ),
                      const SizedBox(height: 6),
                      if (visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            '没有名称含「$keyword」的项目',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      // 排序只决定顺序，不代表 APP 认定谁是对的，
                      // 因此不预先替用户下结论式地标注「推荐」
                      ...visible.map(
                        (m) => _candidate(
                          match: m,
                          selected: selected?.id == m.project.id,
                          current: m.project.id == currentId,
                          onTap: () =>
                              setDialogState(() => selected = m.project),
                        ),
                      ),
                      // 改选别的项目就丢掉了随原项目学到的审核人。
                      // 审核人填错会把日志提交给错误的审批人，必须先说清楚
                      if (currentId.isNotEmpty && selected?.id != currentId)
                        _warning(
                          '你选的不是当前这份配置所属的项目。'
                          '审核人仍沿用「${_auditorLabel(constants)}」，'
                          '请在提交确认框里核对。',
                        ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '确认后会记住 CSV 的「$csvProjectName」对应它，之后不再询问。',
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
                  const ProjectPickResult(confirmed: false),
                ),
                child: Text(_cancelLabel(purpose, matches.isEmpty)),
              ),
              FilledButton(
                // 没选中任何项目时不放行。清单摆在这里却允许「什么都没选就确定」，
                // 等于又给了一条静默走错的路
                onPressed: matches.isNotEmpty && selected == null
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        ProjectPickResult(
                          confirmed: true,
                          // 选的就是当前这份配置所属的项目时不必回传，避免调用方
                          // 拿一份缺少审核人的配置去覆盖完整的那份
                          project: selected?.id == currentId ? null : selected,
                        ),
                      ),
                child: Text(_confirmLabel(purpose, matches.isEmpty)),
              ),
            ],
          );
        },
      ),
    );

    searchController.dispose();
    return result ?? const ProjectPickResult(confirmed: false);
  }

  /// 默认选中哪一个。
  ///
  /// **刻意不把「最接近的」当默认。** 预选就是一次默认同意，而名称接近恰恰是
  /// 这套机制要防的那种「看着像」。只有两种情况才预选：当前配置本来就指向清单里
  /// 的某一项；或者最接近的那个只是空格、全半角写法不同。其余一律留空，
  /// 逼用户自己点一下——多点一次，好过静默记错一个项目。
  static BossProject? _initialSelection(
    List<ProjectMatch> matches,
    String currentId,
  ) {
    for (final m in matches) {
      if (m.project.id == currentId && currentId.isNotEmpty) return m.project;
    }
    if (matches.isEmpty) return null;

    final top = matches.first;
    if (top.level == ProjectMatchLevel.exact ||
        top.level == ProjectMatchLevel.normalized) {
      return top.project;
    }
    return null;
  }

  /// 按关键词过滤。归一化之后比较，用户不必纠结全半角和空格。
  static List<ProjectMatch> _filter(List<ProjectMatch> matches, String keyword) {
    if (keyword.isEmpty) return matches;
    final needle = ProjectNameMatcher.normalize(keyword);
    return matches
        .where(
          (m) => ProjectNameMatcher.normalize(m.project.name).contains(needle),
        )
        .toList();
  }

  /// 一个都没扫到时的退路：把当前配置摆出来做单项确认，不比以前差。
  static List<Widget> _withoutList(
    Map<String, String> constants,
    String currentId,
  ) {
    return [
      _nameRow('BOSS 里学到的', constants['projectName'] ?? ''),
      const SizedBox(height: 10),
      _idRow('项目 ID', currentId),
      _idRow('审核人', _auditorLabel(constants)),
      const SizedBox(height: 12),
      _warning(
        '没能扫到 BOSS 的项目清单，也没找到与 CSV 同名的项目，'
        '上面这个是自动选中的一条。\n'
        '如果你在 BOSS 做过多个项目，它可能不是你要的那个——'
        '确认前请核对项目 ID。',
      ),
    ];
  }

  static String _cancelLabel(ProjectPickPurpose purpose, bool empty) {
    if (purpose == ProjectPickPurpose.change) return '取消';
    return empty ? '不是同一个' : '都不是';
  }

  static String _confirmLabel(ProjectPickPurpose purpose, bool empty) {
    if (purpose == ProjectPickPurpose.change) return '改用选中的';
    return empty ? '是同一个项目' : '就用选中的';
  }

  static Widget _searchField({
    required TextEditingController controller,
    required VoidCallback onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          isDense: true,
          hintText: '搜索项目名',
          hintStyle: TextStyle(fontSize: 12),
          prefixIcon: Icon(Icons.search, size: 18),
          prefixIconConstraints: BoxConstraints(minWidth: 32),
        ),
        onChanged: (_) => onChanged(),
      ),
    );
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
                  // 当前这份配置（含审核人）就是随它一起来的；
                  // 改选别的会连带丢掉审核人，必须说清楚
                  if (current)
                    Text(
                      '当前用的就是它（含审核人配置）',
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
