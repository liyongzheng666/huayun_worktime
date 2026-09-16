import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class DisclaimerDialog extends StatefulWidget {
  final VoidCallback onConfirmed;
  const DisclaimerDialog({super.key, required this.onConfirmed});

  static Future<void> showIfNeeded(
    BuildContext context,
    VoidCallback onConfirmed,
  ) async {
    final storage = StorageService();
    final shown = await storage.loadDisclaimerAccepted();
    if (!context.mounted) return;

    if (!shown) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => DisclaimerDialog(onConfirmed: onConfirmed),
      );
    } else {
      onConfirmed();
    }
  }

  @override
  State<DisclaimerDialog> createState() => _DisclaimerDialogState();
}

class _DisclaimerDialogState extends State<DisclaimerDialog> {
  bool _isConfirming = false;

  Future<void> _confirm() async {
    // 本地保存也有异步间隙，必须在等待前锁住，避免双击重复启动导航。
    if (_isConfirming) return;
    setState(() => _isConfirming = true);
    try {
      await StorageService().saveDisclaimerAccepted(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isConfirming = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败，请重新确认')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 点击遮罩与系统返回是两条关闭路径，首次确认前都不能移除启动入口。
      canPop: false,
      child: AlertDialog(
        title: const Text('免责声明'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('本软件由AI辅助编写，仅供参考。'),
              SizedBox(height: 8),
              Text('使用本软件产生的任何后果由用户自行承担。'),
              SizedBox(height: 8),
              Text('工时数据仅离线本地保存，未上传至任何服务器。'),
              SizedBox(height: 8),
              Text('请妥善保管您的数据，避免丢失。'),
              SizedBox(height: 8),
              Text('如有疑问请联系开发者。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isConfirming ? null : _confirm,
            child: Text(_isConfirming ? '正在保存...' : '我已知晓并同意'),
          ),
        ],
      ),
    );
  }
}
