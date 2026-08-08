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
                  _confirmRow('项目', entry.projectName),
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
