import 'package:flutter/material.dart';

import '../services/app_update_platform.dart';
import '../services/app_update_service.dart';

Future<void> showAppUpdateDialog({
  required BuildContext context,
  required AppUpdateService service,
  required AppUpdateInfo update,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AppUpdateDialog(service: service, update: update),
  );
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.service,
    required this.update,
  });

  final AppUpdateService service;
  final AppUpdateInfo update;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog>
    with WidgetsBindingObserver {
  DownloadedAppUpdate? _downloadedUpdate;
  int _receivedBytes = 0;
  int? _totalBytes;
  bool _isDownloading = false;
  bool _isLaunchingInstaller = false;
  bool _waitingForPermission = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForPermission) {
      _resumeAfterPermissionSettings();
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _receivedBytes = 0;
      _totalBytes = null;
    });

    try {
      final downloaded = await widget.service.downloadUpdate(
        widget.update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
          });
        },
      );
      if (!mounted) return;
      _downloadedUpdate = downloaded;
      setState(() => _isDownloading = false);
      await _continueInstall();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _continueInstall() async {
    final downloaded = _downloadedUpdate;
    if (downloaded == null || _isLaunchingInstaller) return;

    try {
      final allowed = await widget.service.canRequestPackageInstalls();
      if (!allowed) {
        if (!mounted) return;
        setState(() => _waitingForPermission = true);
        return;
      }

      if (!mounted) return;
      setState(() {
        _waitingForPermission = false;
        _isLaunchingInstaller = true;
        _errorMessage = null;
      });
      final result = await widget.service.installDownloadedUpdate(downloaded);
      if (!mounted) return;
      if (result == ApkInstallResult.permissionRequired) {
        setState(() {
          _waitingForPermission = true;
          _isLaunchingInstaller = false;
        });
        return;
      }
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLaunchingInstaller = false;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _openPermissionSettings() async {
    try {
      await widget.service.openInstallPermissionSettings();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    }
  }

  Future<void> _resumeAfterPermissionSettings() async {
    try {
      final allowed = await widget.service.canRequestPackageInstalls();
      if (!mounted || !allowed) return;
      await _continueInstall();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBytes == null || _totalBytes == 0
        ? null
        : _receivedBytes / _totalBytes!;
    final releaseNotes = widget.update.releaseNotes.isEmpty
        ? '本版本未提供更新说明。'
        : widget.update.releaseNotes;

    return AlertDialog(
      title: Text('发现新版本 ${widget.update.displayVersion}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前版本：${widget.update.installedVersion.displayName}'),
              const SizedBox(height: 12),
              const Text('更新说明', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              SelectableText(releaseNotes),
              if (_isDownloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 6),
                Text(
                  _totalBytes == null
                      ? '正在下载…'
                      : '${(_receivedBytes / 1024 / 1024).toStringAsFixed(1)} / '
                            '${(_totalBytes! / 1024 / 1024).toStringAsFixed(1)} MB',
                ),
              ],
              if (_waitingForPermission) ...[
                const SizedBox(height: 16),
                const Text('请允许此应用安装未知来源应用。授权后返回，系统会继续打开安装确认页。'),
              ],
              if (_isLaunchingInstaller) ...[
                const SizedBox(height: 16),
                const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text('正在校验并打开系统安装器…'),
                  ],
                ),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!_isDownloading && !_isLaunchingInstaller)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
        if (_waitingForPermission)
          FilledButton(
            onPressed: _openPermissionSettings,
            child: const Text('去授权'),
          )
        else if (!_isDownloading && !_isLaunchingInstaller)
          FilledButton(
            onPressed: _downloadedUpdate == null
                ? _downloadAndInstall
                : _continueInstall,
            child: Text(_errorMessage == null ? '下载并安装' : '重试'),
          ),
      ],
    );
  }
}
