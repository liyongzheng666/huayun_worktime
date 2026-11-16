import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

class AttendancePhotoException implements Exception {
  const AttendancePhotoException(this.message, {this.refreshAddress = false});
  final String message;
  final bool refreshAddress;
}

/// 图片仅在用户打开时下载；合并在途请求，保存相册复用同一份字节。
class AttendancePhotoLoader {
  AttendancePhotoLoader({
    http.Client Function()? createClient,
    this.timeout = const Duration(seconds: 12),
  }) : _createClient = createClient ?? http.Client.new;

  static final shared = AttendancePhotoLoader();
  final http.Client Function() _createClient;
  final Duration timeout;
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};

  Future<Uint8List> load(String url, {bool retry = false}) {
    if (!retry) {
      final cached = _cache.remove(url);
      if (cached != null) {
        _cache[url] = cached;
        return Future.value(cached);
      }
    }
    return _pending.putIfAbsent(
      url,
      () => _download(url).whenComplete(() {
        _pending.remove(url);
      }),
    );
  }

  Future<Uint8List> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const AttendancePhotoException(
        '照片地址无效，请重新获取',
        refreshAddress: true,
      );
    }
    // 此接口复用 keep-alive 时第二张会挂起；每张独立连接，结束立即关闭。
    final client = _createClient();
    try {
      final bytes = await (() async {
        final response = await client.get(uri);
        if (response.statusCode != 200) {
          throw AttendancePhotoException(
            '照片暂时无法读取，请重试',
            refreshAddress: [401, 403, 404, 410].contains(response.statusCode),
          );
        }
        final data = response.bodyBytes;
        // 200 也可能返回错误文本；确认能解码才缓存，不缓存失败内容。
        try {
          final codec = await ui.instantiateImageCodec(data);
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
        } catch (_) {
          throw const AttendancePhotoException(
            '照片内容无法显示，请重新获取',
            refreshAddress: true,
          );
        }
        return data;
      })().timeout(timeout);
      _cache[url] = bytes;
      // 仅保留最近六张，避免长期查看历史日期积累内存。
      while (_cache.length > 6) {
        _cache.remove(_cache.keys.first);
      }
      return bytes;
    } on TimeoutException {
      throw const AttendancePhotoException('照片加载超时，请重试');
    } on AttendancePhotoException {
      rethrow;
    } catch (_) {
      throw const AttendancePhotoException('照片加载失败，请检查网络后重试');
    } finally {
      client.close();
    }
  }
}
