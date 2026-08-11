import 'package:flutter/material.dart';

import '../core/theme/theme.dart';

/// CSV 项目名与 BOSS 项目名对不上时的绑定确认框
///
/// 决定工时记到哪个项目的是 `PROJECTID`，不是项目名。名字对不上说明 APP
/// **没能**在 BOSS 的历史日志里找到同名项目，只能退而取到一条记录——用户
/// 在 BOSS 做过多个项目时，这一条完全可能属于别的项目，且提交不会报错。
///
/// 因此这里必须把项目 ID 摆出来让用户核对，而不是替他猜；确认后记住绑定
/// 关系，同一个 CSV 项目名之后不再询问，也不再每次重学。
class WorkLogBindingConfirmDialog {
  WorkLogBindingConfirmDialog._();

  /// 返回 true 表示用户确认两者是同一个项目。
  static Future<bool> show({
    required BuildContext context,
    required String csvProjectName,
    required Map<String, String> constants,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      // 绑错项目的后果是工时记到别人名下，不能让用户点外面糊弄过去
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('项目名对不上'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _nameRow('CSV 里写的', csvProjectName),
              _nameRow('BOSS 里学到的', constants['projectName'] ?? ''),
              const SizedBox(height: 10),
              // 项目 ID 才是真正决定归属的字段，必须显式给出来
              _idRow('项目 ID', constants['projectId'] ?? ''),
              _idRow(
                '审核人',
                constants['auditorName']?.isNotEmpty == true
                    ? constants['auditorName']!
                    : '（未知，仅有 ID）',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warningLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.warning),
                ),
                child: Text(
                  '没能在 BOSS 的历史日志里找到与 CSV 同名的项目，'
                  '上面这个是自动选中的一条。\n'
                  '如果你在 BOSS 做过多个项目，它可能不是你要的那个——'
                  '确认前请核对项目 ID。',
                  style: TextStyle(fontSize: 12, color: AppColors.warningDark),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '确认后会记住这个对应关系，之后不再询问。',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('不是同一个'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('是同一个项目'),
          ),
        ],
      ),
    );

    return result == true;
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
