import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/work_log_repository.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_time_calculator.dart';

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
  /// 返回最终要提交的工时字符串；取消或输入非法时返回 null。
  ///
  /// 工时默认取打卡统计值，但必须可改：打卡异常、出差、补录等场景下
  /// 打卡值并不等于该报的工时，而这是唯一能在提交前修正它的地方。
  static Future<String?> show({
    required BuildContext context,
    required String date,
    required WorkLogEntry entry,
    required WorkLogHours hours,
    required double? existingHours,
    required Map<String, String> constants,
  }) async {
    final alreadyFiled = existingHours != null && existingHours > 0;

    // 没有打卡数据时留空，由用户自己填，而不是拦在门外
    final punchText = hours.hasData
        ? WorkTimeCalculator.formatHours(hours.hours!)
        : '';
    final hoursController = TextEditingController(text: punchText);

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final parsed = WorkTimeCalculator.parseHoursInput(
            hoursController.text,
          );
          final edited = parsed != null && punchText.isNotEmpty &&
              WorkTimeCalculator.formatHours(parsed) != punchText;

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
                        '未能确认当天是否已填报，请提交后自行核对。',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ),
                  // 项目与审核人是这里最有后果的两项：填错项目会把工时记到
                  // 别的项目名下，填错审核人会把日志提交给错误的审批人。
                  // 两者都不是用户输入的，而是 APP 自动查来的，因此必须让他能核对。
                  _buildProjectRow(
                    csvName: entry.projectName,
                    bossName: constants['projectName'] ?? '',
                  ),
                  _confirmRow(
                    '审核人',
                    constants['auditorName']?.isNotEmpty == true
                        ? constants['auditorName']!
                        : '（未知，仅有 ID）',
                  ),
                  _confirmRow('标题', entry.title),
                  _confirmRow('工作类型', entry.workType),
                  _confirmRow('项目阶段', entry.stage),
                  _confirmRow('阶段活动', entry.activity),
                  _buildHoursField(
                    controller: hoursController,
                    punchText: punchText,
                    parsed: parsed,
                    edited: edited,
                    onChanged: () => setDialogState(() {}),
                  ),
                  _buildStepHint(
                    parsed: parsed,
                    // 手改过工时之后，打卡时刻和输入框里的数已经对不上，
                    // 再给「打卡到几点」只会指向一个错的时间
                    checkOut: edited ? null : hours.checkOut,
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
                // 工时非法时不给提交，避免把脏值发到公司系统
                onPressed: parsed == null
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        WorkTimeCalculator.formatHours(parsed),
                      ),
                // 已填报时改用「仍要提交」，让重复提交成为一个需要刻意确认的动作
                child: Text(alreadyFiled ? '仍要提交' : '确认提交'),
              ),
            ],
          );
        },
      ),
    );

    hoursController.dispose();
    return result;
  }

  /// 可编辑的工时输入行。
  ///
  /// 打卡值作为默认值和参照同时显示：改过之后仍能看到原始打卡工时是多少，
  /// 否则用户改完就无从判断自己偏离了多少。
  static Widget _buildHoursField({
    required TextEditingController controller,
    required String punchText,
    required double? parsed,
    required bool edited,
    required VoidCallback onChanged,
  }) {
    final String helper;
    if (punchText.isEmpty) {
      helper = '当天没有打卡工时，请手动填写';
    } else if (edited) {
      helper = '打卡工时为 $punchText，已手动调整';
    } else {
      helper = '来自打卡统计，可修改';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '工时',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
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
  static Widget _buildProjectRow({
    required String csvName,
    required String bossName,
  }) {
    // 手工配置的没有 BOSS 名，此时提交的就是 CSV 的写法
    if (bossName.isEmpty || bossName == csvName) {
      return _confirmRow('项目', csvName);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '项目',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          Text(bossName, style: const TextStyle(fontSize: 13)),
          Text(
            'CSV 里写的是「$csvName」，已按 BOSS 的名称提交',
            style: TextStyle(fontSize: 10, color: Colors.grey[600]),
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
  static Widget _buildStepHint({
    required double? parsed,
    required String? checkOut,
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
    final checkOutMinutes = WorkTimeCalculator.parseTimeToMinutes(checkOut);
    final targetClock = checkOutMinutes == null
        ? null
        : WorkTimeCalculator.minutesToTimeStr(checkOutMinutes + needMinutes);

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
          Text(value.isEmpty ? '（空）' : value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
