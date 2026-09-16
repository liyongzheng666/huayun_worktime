import 'package:flutter/material.dart';

import '../utils/haptic_utils.dart';

class TeamSelectionDialog {
  TeamSelectionDialog._();

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required List<Map<String, dynamic>> teams,
    String? currentTeamNo,
    bool barrierDismissible = false,
    bool showCancel = false,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) {
        return PopScope(
          // 首次登录必须选定团队；设置页明确允许取消时保留系统返回。
          canPop: showCancel || barrierDismissible,
          child: AlertDialog(
            title: const Text('选择团队'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: teams.length,
                itemBuilder: (context, index) {
                  final team = teams[index];
                  final teamName = team['teamName'] as String? ?? '未知团队';
                  final teamNo = team['teamNo'] as String?;
                  final isCurrentTeam =
                      currentTeamNo != null && teamNo == currentTeamNo;
                  return ListTile(
                    title: Text(teamName),
                    trailing: isCurrentTeam
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                    onTap: () {
                      HapticUtils.selectionClick();
                      Navigator.of(context).pop(team);
                    },
                  );
                },
              ),
            ),
            actions: showCancel
                ? [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('取消'),
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}
