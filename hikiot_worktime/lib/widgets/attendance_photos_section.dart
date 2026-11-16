import 'package:flutter/material.dart';

import '../screens/photo_preview_screen.dart';
import '../utils/attendance_parser.dart';

/// 只有点击具体照片时才补查旧缓存；打开日期窗口不触发任何照片请求。
class AttendancePhotosSection extends StatefulWidget {
  const AttendancePhotosSection({
    super.key,
    required this.date,
    required this.dayData,
    required this.loadPhotos,
  });

  final String date;
  final Map<String, dynamic> dayData;
  final Future<AttendanceData> Function() loadPhotos;

  @override
  State<AttendancePhotosSection> createState() =>
      _AttendancePhotosSectionState();
}

class _AttendancePhotosSectionState extends State<AttendancePhotosSection> {
  String? _loadingKind;
  bool _failed = false;
  late bool _checkInKnown;
  late bool _checkOutKnown;
  late String? _checkInPhoto;
  late String? _checkOutPhoto;

  @override
  void initState() {
    super.initState();
    _checkInPhoto = widget.dayData['checkInPhotoUrl'] as String?;
    _checkOutPhoto = widget.dayData['checkOutPhotoUrl'] as String?;
    _checkInKnown = widget.dayData.containsKey('checkInPhotoUrl');
    _checkOutKnown = widget.dayData.containsKey('checkOutPhotoUrl');
  }

  Future<void> _openPhoto(String kind) async {
    if (_loadingKind != null) return;
    final known = kind == 'in' ? _checkInKnown : _checkOutKnown;
    if (!known) {
      setState(() {
        _loadingKind = kind;
        _failed = false;
      });
      try {
        // 一次日接口同时返回上下班地址，另一个按钮也复用本次结果。
        final photos = await widget.loadPhotos();
        if (!mounted) return;
        setState(() {
          _checkInPhoto = photos.checkInPhotoUrl;
          _checkOutPhoto = photos.checkOutPhotoUrl;
          _checkInKnown = true;
          _checkOutKnown = true;
          _loadingKind = null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loadingKind = null;
          _failed = true;
        });
        return;
      }
    }
    final url = (kind == 'in' ? _checkInPhoto : _checkOutPhoto)?.trim();
    if (url == null || url.isEmpty || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoPreviewScreen(
          photoUrl: url,
          heroTag: 'attendance-${widget.date}-$kind',
        ),
      ),
    );
  }

  Widget _photoButton(String label, String? url, String kind) {
    final photoUrl = url?.trim();
    final known = kind == 'in' ? _checkInKnown : _checkOutKnown;
    final unavailable = known && (photoUrl == null || photoUrl.isEmpty);
    return OutlinedButton.icon(
      icon: const Icon(Icons.photo_outlined),
      label: Text(
        _loadingKind == kind
            ? '正在查询$label照片…'
            : unavailable
            ? '暂无$label照片'
            : '查看$label照片',
      ),
      onPressed: unavailable || _loadingKind != null
          ? null
          : () => _openPhoto(kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('打卡照片', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_failed) const Text('照片查询失败，请点击照片重试'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _photoButton('上班', _checkInPhoto, 'in'),
              _photoButton('下班', _checkOutPhoto, 'out'),
            ],
          ),
        ],
      ),
    );
  }
}
