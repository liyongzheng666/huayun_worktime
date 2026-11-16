import 'package:flutter/material.dart';

import 'attendance_photo_dialog.dart';
import '../utils/attendance_parser.dart';
import '../services/attendance_photo_loader.dart';

/// 只有点击具体照片时才补查旧缓存；打开日期窗口不触发任何照片请求。
class AttendancePhotosSection extends StatefulWidget {
  const AttendancePhotosSection({
    super.key,
    required this.date,
    required this.dayData,
    required this.loadPhotos,
    this.photoLoader,
  });

  final String date;
  final Map<String, dynamic> dayData;
  final Future<AttendanceData> Function(bool forceRefresh) loadPhotos;
  final AttendancePhotoLoader? photoLoader;

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
        final photos = await widget.loadPhotos(false);
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
    await showDialog<void>(
      context: context,
      builder: (_) => AttendancePhotoDialog(
        photoUrl: url,
        loader: widget.photoLoader,
        title: kind == 'in' ? '上班照片' : '下班照片',
        refreshPhotoUrl: () async {
          final photos = await widget.loadPhotos(true);
          if (mounted) {
            setState(() {
              _checkInPhoto = photos.checkInPhotoUrl;
              _checkOutPhoto = photos.checkOutPhotoUrl;
              _checkInKnown = true;
              _checkOutKnown = true;
            });
          }
          return kind == 'in'
              ? photos.checkInPhotoUrl
              : photos.checkOutPhotoUrl;
        },
      ),
    );
  }

  Widget _photoButton(String label, String? url, String kind) {
    final photoUrl = url?.trim();
    final known = kind == 'in' ? _checkInKnown : _checkOutKnown;
    final unavailable = known && (photoUrl == null || photoUrl.isEmpty);
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: unavailable || _loadingKind != null
          ? null
          : () => _openPhoto(kind),
      child: Text(
        _loadingKind == kind
            ? '查询$label…'
            : unavailable
            ? '暂无$label照片'
            : '$label照片',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_failed) const Text('照片查询失败，请点击照片重试'),
          Row(
            children: [
              Expanded(child: _photoButton('上班', _checkInPhoto, 'in')),
              const SizedBox(width: 8),
              Expanded(child: _photoButton('下班', _checkOutPhoto, 'out')),
            ],
          ),
        ],
      ),
    );
  }
}
