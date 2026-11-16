import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../services/attendance_photo_loader.dart';

/// 在日详情上方查看照片；关闭后回到原窗口，不另开整页。
class AttendancePhotoDialog extends StatefulWidget {
  const AttendancePhotoDialog({
    super.key,
    required this.photoUrl,
    this.title = '打卡照片',
    this.refreshPhotoUrl,
    this.loader,
  });

  final String photoUrl;
  final String title;
  final Future<String?> Function()? refreshPhotoUrl;
  final AttendancePhotoLoader? loader;

  @override
  State<AttendancePhotoDialog> createState() => _AttendancePhotoDialogState();
}

class _AttendancePhotoDialogState extends State<AttendancePhotoDialog> {
  late final _loader = widget.loader ?? AttendancePhotoLoader.shared;
  late String _url = widget.photoUrl;
  Uint8List? _bytes;
  AttendancePhotoException? _error;
  bool _loading = true;
  bool _saving = false;
  String? _saveMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool retry = false}) async {
    final refreshAddress = retry && _error?.refreshAddress == true;
    setState(() {
      _loading = true;
      _error = null;
      _saveMessage = null;
    });
    try {
      if (refreshAddress && widget.refreshPhotoUrl != null) {
        final fresh = await widget.refreshPhotoUrl!().timeout(_loader.timeout);
        if (!mounted) return;
        if (fresh == null || fresh.trim().isEmpty) {
          throw const AttendancePhotoException('当天暂无这张照片');
        }
        _url = fresh.trim();
      }
      final bytes = await _loader.load(_url, retry: retry);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _error = const AttendancePhotoException('照片加载超时，请重试');
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AttendancePhotoException
            ? error
            : const AttendancePhotoException('照片加载失败，请重试');
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    String message;
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        message = '需要相册权限才能保存';
      } else {
        await Gal.putImageBytes(
          bytes,
          name: 'worktime_${DateTime.now().microsecondsSinceEpoch}',
        );
        message = '已保存到相册';
      }
    } catch (_) {
      message = '保存失败，请检查相册权限后重试';
    }
    if (mounted) {
      setState(() {
        _saving = false;
        _saveMessage = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * .45).clamp(
      100.0,
      360.0,
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭照片',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              SizedBox(
                height: height,
                width: double.infinity,
                child: _loading
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(strokeWidth: 2),
                          SizedBox(height: 12),
                          Text('正在加载照片…'),
                        ],
                      )
                    : _error != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_error!.message, textAlign: TextAlign.center),
                          TextButton(
                            onPressed: () => _load(retry: true),
                            child: const Text('重新加载'),
                          ),
                        ],
                      )
                    : InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: Image.memory(
                          _bytes!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_saveMessage != null)
                    Expanded(
                      child: Text(
                        _saveMessage!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  TextButton.icon(
                    onPressed: _loading || _error != null || _saving
                        ? null
                        : _save,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(_saving ? '保存中…' : '保存图片'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
