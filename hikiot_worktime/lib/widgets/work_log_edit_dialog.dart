import 'package:flutter/material.dart';

import '../utils/work_log_edit_script.dart';
import '../utils/work_time_calculator.dart';

class WorkLogEditOutcome {
  const WorkLogEditOutcome({
    required this.title,
    required this.content,
    required this.actWork,
  });

  final String title;
  final String content;
  final String actWork;
}

/// 已提交日志编辑框。
///
/// 第一版只开放已由真机抓包验证过的普通字段：标题、内容、时长。项目、审核人、
/// 类型等仍展示服务端原值但不在这里改，避免触发额外的外键保存协议。
class WorkLogEditDialog {
  WorkLogEditDialog._();

  static Future<WorkLogEditOutcome?> show({
    required BuildContext context,
    required BossWorkLogRecord record,
  }) {
    return showDialog<WorkLogEditOutcome>(
      context: context,
      builder: (_) => _WorkLogEditDialogBody(record: record),
    );
  }
}

class _WorkLogEditDialogBody extends StatefulWidget {
  const _WorkLogEditDialogBody({required this.record});

  final BossWorkLogRecord record;

  @override
  State<_WorkLogEditDialogBody> createState() => _WorkLogEditDialogBodyState();
}

class _WorkLogEditDialogBodyState extends State<_WorkLogEditDialogBody> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late final TextEditingController _hoursController;

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _titleController = TextEditingController(text: record.title);
    _contentController = TextEditingController(text: record.content);
    _hoursController = TextEditingController(
      text: record.hours == null
          ? ''
          : WorkTimeCalculator.formatHours(record.hours!),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final hours = WorkTimeCalculator.parseHoursInput(_hoursController.text);
    final valid = title.isNotEmpty && content.isNotEmpty && hours != null;
    final changed =
        title != record.title ||
        content != record.content ||
        (hours != null &&
            WorkTimeCalculator.formatHours(hours) !=
                WorkTimeCalculator.formatHours(record.hours ?? 0));

    return AlertDialog(
      title: Text('编辑 ${record.date.isEmpty ? '已提交日志' : record.date}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (record.projectName.isNotEmpty) ...[
              Text(
                record.projectName,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '标题',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentController,
              decoration: const InputDecoration(
                labelText: '工作内容',
                border: OutlineInputBorder(),
              ),
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hoursController,
              decoration: const InputDecoration(
                labelText: '工作时长（小时）',
                border: OutlineInputBorder(),
                suffixText: '小时',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              '保存会修改 BOSS 中原来的记录，不会新增日志。',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: !valid || !changed
              ? null
              : () => Navigator.pop(
                  context,
                  WorkLogEditOutcome(
                    title: title,
                    content: content,
                    actWork: WorkTimeCalculator.formatHours(hours),
                  ),
                ),
          child: const Text('保存修改'),
        ),
      ],
    );
  }
}
