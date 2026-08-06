import 'package:flutter/material.dart';

import '../services/storage_service.dart';

/// BOSS 提交配置对话框
///
/// 提交日志需要三个无法从 CSV 或打卡数据推导的业务标识。自动发现试过多种
/// 途径（查历史日志、扫抓包、模拟点菜单）都不稳定——BOSS 是有状态的 SPA，
/// 外部脚本很难可靠地驱动它。因此提供手工配置作为可靠入口。
///
/// 这些是业务标识而非凭据，可以安全地本地保存；也不写死在代码里，
/// 换项目、换审核人时用户自己就能改。
class BossConstantsDialog extends StatefulWidget {
  const BossConstantsDialog({super.key});

  /// 打开对话框，保存成功返回 true。
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const BossConstantsDialog(),
    );
    return result == true;
  }

  @override
  State<BossConstantsDialog> createState() => _BossConstantsDialogState();
}

class _BossConstantsDialogState extends State<BossConstantsDialog> {
  final _projectIdController = TextEditingController();
  final _projectCodeController = TextEditingController();
  final _auditorController = TextEditingController();
  final _storage = StorageService();

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await _storage.loadBossConstants();
    if (!mounted) return;
    setState(() {
      _projectIdController.text = saved['projectId'] ?? '';
      _projectCodeController.text = saved['projectCode'] ?? '';
      _auditorController.text = saved['auditor'] ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _projectIdController.dispose();
    _projectCodeController.dispose();
    _auditorController.dispose();
    super.dispose();
  }

  /// 项目 ID 是提交的必要条件，其余两项允许留空由服务端兜底。
  bool get _isValid => _projectIdController.text.trim().isNotEmpty;

  Future<void> _save() async {
    await _storage.saveBossConstants({
      'projectId': _projectIdController.text.trim(),
      'projectCode': _projectCodeController.text.trim(),
      'auditor': _auditorController.text.trim(),
    });
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('BOSS 提交配置'),
      content: _loading
          ? const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '这三个值来自 BOSS 的日志记录，填一次即可长期使用。',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 14),
                  _buildField(
                    controller: _projectIdController,
                    label: '项目 ID（必填）',
                    hint: 'PROJECT_xxxxxxxx',
                  ),
                  _buildField(
                    controller: _projectCodeController,
                    label: '项目编码',
                    hint: 'PROJECT_xxxxxxxx',
                  ),
                  _buildField(
                    controller: _auditorController,
                    label: '审核人 ID',
                    hint: ';USERINFO_xxxxxxxx',
                    helper: '注意保留开头的分号',
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isValid ? _save : null,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperStyle: const TextStyle(fontSize: 10),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        // 值较长，允许换行显示以便核对
        maxLines: null,
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}
