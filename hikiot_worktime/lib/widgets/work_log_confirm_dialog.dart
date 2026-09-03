import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/work_log_repository.dart';
import '../utils/date_helper.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_time_calculator.dart';

/// 用户在提交确认框里的选择
class WorkLogConfirmOutcome {
  /// 确认提交，[actWork] 是最终工时
  const WorkLogConfirmOutcome.submit(this.actWork)
    : changeProject = false,
      changeAuditor = false;

  /// 要求改选项目，回到项目选择框
  const WorkLogConfirmOutcome.changeProject()
    : actWork = null,
      changeProject = true,
      changeAuditor = false;

  /// 要求改选审核人，回到审核人选择框
  const WorkLogConfirmOutcome.changeAuditor()
    : actWork = null,
      changeProject = false,
      changeAuditor = true;

  final String? actWork;
  final bool changeProject;
  final bool changeAuditor;
}

/// 提交前的核对对话框
///
/// 从网页页面里抽出来共用：后台提交与网页内提交必须弹同一个框，
/// 否则两条路径的核对项容易走偏，而这里恰恰是提交到公司系统前
/// 唯一的人工关卡。
class WorkLogConfirmDialog {
  WorkLogConfirmDialog._();

  /// 提交前让用户核对内容，并允许调整工时。
  ///
  /// 面向公司真实系统，绝不静默提交。
  /// 返回用户的选择；取消或输入非法时返回 null。
  ///
  /// 工时默认取打卡统计值，但必须可改：打卡异常、出差、补录等场景下
  /// 打卡值并不等于该报的工时，而这是唯一能在提交前修正它的地方。
  ///
  /// [canChangeProject] 为 true 时项目那一行给出「改选」入口。项目名一旦绑定
  /// 就不再询问，如果当初绑错了，这里是用户唯一能自己纠正的地方——否则他只能
  /// 去「提交配置」里手填一串 `PROJECT_xxxxxxxx`。调用方在扫到项目清单时才该
  /// 给 true：清单都没有，点开也没得选。
  static Future<WorkLogConfirmOutcome?> show({
    required BuildContext context,
    required String date,
    required WorkLogEntry entry,
    required WorkLogHours hours,
    required double? existingHours,
    required Map<String, String> constants,
    bool canChangeProject = false,
    bool canChangeAuditor = false,
    DateTime? now,
  }) async {
    final alreadyFiled = existingHours != null && existingHours > 0;

    // 没有打卡数据时留空，由用户自己填，而不是拦在门外
    final punchText = hours.hasData
        ? WorkTimeCalculator.formatHours(hours.hours!)
        : '';
    final hoursController = TextEditingController(text: punchText);

    // 「按当前时间」只在**今天**且有上班打卡时才谈得上：拿此刻去减一个
    // 过去日期的上班时间，算出来的是个毫无意义的大数。
    final canUseNow =
        hours.checkIn?.isNotEmpty == true &&
        DateHelper.isTodayStr(date, now: now);
    var useCheckIn = true;

    final result = await showDialog<WorkLogConfirmOutcome>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 「当前时间」是随时在走的，每次重建都重算一次，
          // 而不是打开对话框那一刻算完就钉死
          final nowHours = canUseNow
              ? WorkTimeCalculator.hoursFromCheckInToNow(
                  hours.checkIn,
                  now: now,
                )
              : null;
          final nowText = nowHours == null
              ? ''
              : WorkTimeCalculator.formatHours(nowHours);

          // 当前模式下「未经手改」的基准值。改模式时输入框会跟着回到它，
          // edited 的判定也以它为准——否则切一次模式就永远显示「已手动调整」
          final sourceText = useCheckIn || !canUseNow ? punchText : nowText;

          final parsed = WorkTimeCalculator.parseHoursInput(
            hoursController.text,
          );
          final edited =
              parsed != null &&
              sourceText.isNotEmpty &&
              WorkTimeCalculator.formatHours(parsed) != sourceText;

          void switchSource(bool toCheckIn) {
            setDialogState(() {
              useCheckIn = toCheckIn;
              // 切换即以新来源的值为准。手改过的值也会被覆盖——
              // 用户点这个开关就是在说「按这个来源重算」
              hoursController.text = toCheckIn ? punchText : nowText;
            });
          }

          return AlertDialog(
            title: Text('提交 $date 的日志？'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // BOSS 不做去重，这里必须显式警示，否则会静默产生重复日志
                  if (alreadyFiled)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.warningLight,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.warning),
                      ),
                      child: Text(
                        '⚠️ 这一天在 BOSS 已填报 '
                        '${WorkTimeCalculator.formatHours(existingHours)} 小时。\n'
                        '继续提交会新增一条记录，不会覆盖原有记录。',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warningDark,
                        ),
                      ),
                    ),
                  if (existingHours == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        '未能确认当天是否已填报，本次将暂缓提交，请稍后重试。',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ),
                  // 项目与审核人是这里最有后果的两项：填错项目会把工时记到
                  // 别的项目名下，填错审核人会把日志提交给错误的审批人。
                  // 两者都不是用户输入的，而是 APP 自动查来的，因此必须让他能核对。
                  _buildProjectRow(
                    csvName: entry.projectName,
                    bossName: constants['projectName'] ?? '',
                    projectId: constants['projectId'] ?? '',
                    onChange: canChangeProject
                        ? () => Navigator.pop(
                            dialogContext,
                            const WorkLogConfirmOutcome.changeProject(),
                          )
                        : null,
                  ),
                  _buildAuditorRow(
                    constants: constants,
                    onChange: canChangeAuditor
                        ? () => Navigator.pop(
                            dialogContext,
                            const WorkLogConfirmOutcome.changeAuditor(),
                          )
                        : null,
                  ),
                  _confirmRow('标题', entry.title),
                  _confirmRow('工作类型', entry.workType),
                  _confirmRow('项目阶段', entry.stage),
                  _confirmRow('阶段活动', entry.activity),
                  if (canUseNow)
                    _buildSourceSwitch(
                      useCheckIn: useCheckIn,
                      punchText: punchText,
                      nowText: nowText,
                      onSwitch: switchSource,
                    ),
                  _buildHoursField(
                    controller: hoursController,
                    sourceText: sourceText,
                    sourceLabel: useCheckIn || !canUseNow ? '打卡工时' : '按当前时间',
                    parsed: parsed,
                    edited: edited,
                    onChanged: () => setDialogState(() {}),
                  ),
                  _buildStepHint(
                    parsed: parsed,
                    // 手改过工时之后，参照时刻和输入框里的数已经对不上，
                    // 再给「几点」只会指向一个错的时间。
                    //
                    // 参照时刻随来源走：按打卡算时是下班打卡时刻，
                    // 按当前时间算时就是此刻——「再待 3 分钟」是从现在起算的。
                    baseClock: edited
                        ? null
                        : (useCheckIn || !canUseNow
                              ? hours.checkOut
                              : DateHelper.nowClock(now: now)),
                  ),
                  const Divider(),
                  _confirmRow('工作内容', entry.content),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: const Text('取消'),
              ),
              FilledButton(
                // 已填或查询状态未知时都不允许提交。BOSS 不做幂等，
                // “仍要提交”会把一次网络抖动变成同日两条重复日志。
                onPressed:
                    parsed == null || existingHours == null || alreadyFiled
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        WorkLogConfirmOutcome.submit(
                          WorkTimeCalculator.formatHours(parsed),
                        ),
                      ),
                child: Text(
                  alreadyFiled
                      ? '该日已提交'
                      : existingHours == null
                      ? '暂缓提交'
                      : '确认提交',
                ),
              ),
            ],
          );
        },
      ),
    );

    hoursController.dispose();
    return result;
  }

  /// 工时来源切换：按打卡 / 按当前时间。
  ///
  /// **为什么需要它**：下班卡还没打的时候，打卡统计出来的工时要么是空的、
  /// 要么停在中午。想现在就把日报报掉，就得按「此刻」算。每日工时页早就有
  /// 这个开关，提交日报这里反而只能按打卡走，得手算了再手填。
  ///
  /// 两个选项都把各自算出来的小时数写在标签上，切换前就能看清差多少，
  /// 不用切过去才知道。
  static Widget _buildSourceSwitch({
    required bool useCheckIn,
    required String punchText,
    required String nowText,
    required ValueChanged<bool> onSwitch,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '工时来源',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          // Wrap 而非 Row：两个按钮带上小时数之后不算短，
          // 系统字体放大时挤在一行会溢出
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _sourceChip(
                label: punchText.isEmpty ? '打卡（无数据）' : '打卡 $punchText h',
                selected: useCheckIn,
                onTap: () => onSwitch(true),
              ),
              _sourceChip(
                label: nowText.isEmpty ? '当前时间（算不出）' : '当前时间 $nowText h',
                selected: !useCheckIn,
                onTap: () => onSwitch(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _sourceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.infoLight : null,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.info : Colors.grey.shade300,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 14,
              color: selected ? AppColors.info : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : null,
                color: selected ? AppColors.infoDark : Colors.grey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 可编辑的工时输入行。
  ///
  /// 来源值作为默认值和参照同时显示：改过之后仍能看到原始值是多少，
  /// 否则用户改完就无从判断自己偏离了多少。
  static Widget _buildHoursField({
    required TextEditingController controller,
    required String sourceText,
    required String sourceLabel,
    required double? parsed,
    required bool edited,
    required VoidCallback onChanged,
  }) {
    final String helper;
    if (sourceText.isEmpty) {
      helper = '当天没有可用工时，请手动填写';
    } else if (edited) {
      helper = '$sourceLabel为 $sourceText，已手动调整';
    } else {
      helper = '来自$sourceLabel，可修改';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('工时', style: TextStyle(fontSize: 11, color: Colors.grey)),
          TextField(
            controller: controller,
            autofocus: false,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              suffixText: '小时',
              helperText: parsed == null ? null : helper,
              helperStyle: TextStyle(
                fontSize: 10,
                color: edited ? AppColors.warningDark : Colors.grey[600],
              ),
              // 非法时说清楚合法范围，而不是只说「错了」
              errorText: parsed == null ? '请填 0 到 24 之间的数字' : null,
              errorStyle: const TextStyle(fontSize: 10),
            ),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }

  /// 项目行。
  ///
  /// 显示的是 **BOSS 那边的项目名**，因为提交上去的就是它——报文里的
  /// `PROJECTNAME` 必须跟 `PROJECTID` 同源。CSV 的写法与之不同时（比如少一个
  /// 「(2)」）额外标出来：两个名字都摆着，用户才能发现绑错了项目。
  ///
  /// [onChange] 非空时右侧给出「改选」。发现绑错了却只能眼看着提交，
  /// 或者跑去手填一串 `PROJECT_xxxxxxxx`，都不该是这里的唯一出路。
  static Widget _buildProjectRow({
    required String csvName,
    required String bossName,
    String projectId = '',
    VoidCallback? onChange,
  }) {
    // 手工配置的没有 BOSS 名，此时提交的就是 CSV 的写法
    final display = bossName.isEmpty ? csvName : bossName;
    final differs = bossName.isNotEmpty && bossName != csvName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '项目',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const Spacer(),
              if (onChange != null)
                TextButton(
                  onPressed: onChange,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('改选', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          Text(
            display.isEmpty ? '（空）' : display,
            style: const TextStyle(fontSize: 13),
          ),
          if (differs)
            Text(
              'CSV 里写的是「$csvName」，已按 BOSS 的名称提交',
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
          // 没有 BOSS 项目名时，上面显示的其实是 CSV 的写法，**没有任何东西
          // 证明它和 PROJECTID 指向同一个项目**。这里必须说破：以前不说，
          // 用户看到的是一个「看起来完全正常」的项目名，于是把日志提交到了
          // 别的项目下也毫无察觉。
          if (bossName.isEmpty)
            Text(
              '⚠️ 未能确认 BOSS 那边的项目名，上面是 CSV 的写法。'
              '决定工时记到哪个项目的是项目 ID，请核对：'
              '${projectId.isEmpty ? '（空）' : projectId}',
              style: TextStyle(fontSize: 10, color: AppColors.warningDark),
            ),
        ],
      ),
    );
  }

  /// 审核人行。
  ///
  /// 审核人是这个框里和项目并列的两个「填错就有实际后果」的字段：填错项目把
  /// 工时记到别人名下，填错审核人把日志发给错误的审批人。两者都不是用户输入的，
  /// 所以都必须能核对、也都必须能改。
  ///
  /// **只有 ID 没有姓名时要说破**：显示成空白会让人以为是渲染问题，
  /// 而这里的空白恰恰意味着「没法用肉眼核对是不是对的人」。
  static Widget _buildAuditorRow({
    required Map<String, String> constants,
    VoidCallback? onChange,
  }) {
    final name = constants['auditorName'] ?? '';
    final id = constants['auditor'] ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '审核人',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const Spacer(),
              if (onChange != null)
                TextButton(
                  onPressed: onChange,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('改选', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          Text(
            name.isNotEmpty ? name : '（未取到姓名）',
            style: TextStyle(
              fontSize: 13,
              color: name.isEmpty ? AppColors.warningDark : null,
            ),
          ),
          if (name.isEmpty)
            Text(
              id.isEmpty ? '⚠️ 还没有审核人，无法提交' : '⚠️ 只取到 ID：$id，没法用姓名核对是不是对的人',
              style: TextStyle(fontSize: 10, color: AppColors.warningDark),
            ),
        ],
      ),
    );
  }

  /// 凑整建议：距离下一个 0.1 小时刻度还差几分钟。
  ///
  /// BOSS 的工时只到一位小数，打卡 11.55 报上去零头就没了；差的往往只有
  /// 两三分钟，知道了就能选择多待一会儿再补打下班卡。
  ///
  /// **只提示，不代改工时**：工时框里必须始终是实际打卡值，
  /// 要不要为了凑整多待几分钟是用户自己的决定，APP 替他改就成了虚报。
  ///
  /// 基准取输入框当前值而非打卡工时——提交出去的是前者，
  /// 用户手改之后提示还盯着打卡值会自相矛盾。
  ///
  /// [baseClock] 是「再待 N 分钟」的起算时刻，随工时来源走：按打卡算时是
  /// 下班打卡时刻，按当前时间算时就是此刻。给错了，「打卡到几点」会指向
  /// 一个用户照着做反而更错的时间。
  static Widget _buildStepHint({
    required double? parsed,
    required String? baseClock,
  }) {
    // 工时非法时提交按钮本就是灰的，此时给凑整建议只会喧宾夺主
    if (parsed == null) return const SizedBox.shrink();

    final needMinutes = WorkTimeCalculator.minutesToNextBossStep(parsed);
    if (needMinutes == 0) {
      // 不需要等也要说一声，否则用户无从判断这条提示是没算还是不用等
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        child: Text(
          '工时已是 0.1 小时的整数倍，不用再等',
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
      );
    }

    final target = WorkTimeCalculator.formatHours(
      WorkTimeCalculator.nextBossStepHours(parsed),
    );

    // 换算成具体几点，「再待 3 分钟」才是照着能做的事
    final baseMinutes = WorkTimeCalculator.parseTimeToMinutes(baseClock);
    final targetClock = baseMinutes == null
        ? null
        : WorkTimeCalculator.minutesToTimeStr(baseMinutes + needMinutes);

    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.infoLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.info),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '💡 再待 $needMinutes 分钟可凑满 $target 小时',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.infoDark,
              fontWeight: FontWeight.w600,
            ),
          ),
          // 工时是打开页面时的快照，等完不刷新就白等了：提交的还是旧值
          if (targetClock != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '打卡到 $targetClock 后下拉刷新本页，再提交',
                style: TextStyle(fontSize: 11, color: AppColors.infoDark),
              ),
            ),
        ],
      ),
    );
  }

  static Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            value.isEmpty ? '（空）' : value,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
