import 'package:flutter/material.dart';

import '../core/theme/app_skin.dart';
import 'storage_service.dart';

/// 主题立即切换，磁盘写入排队执行，避免快速连点时旧值覆盖新值。
class AppThemeController extends ChangeNotifier {
  AppThemeController({StorageService? storage})
    : _storage = storage ?? StorageService();

  static final shared = AppThemeController();
  final StorageService _storage;
  AppSkin _current = AppSkin.defaultSkin;
  AppSkin _persisted = AppSkin.defaultSkin;
  Future<void> _pending = Future<void>.value();
  int _revision = 0;

  AppSkin get current => _current;
  ThemeData get themeData => _current.themeData;

  Future<void> load() async {
    final revision = _revision;
    try {
      final id = await _storage.loadAppSkinId();
      final skin = AppSkin.byId(id) ?? AppSkin.defaultSkin;
      if (revision != _revision) return;
      _persisted = skin;
      _current = skin;
      notifyListeners();
    } catch (_) {
      // 存储不可用时仍能使用默认主题，不阻塞登录和查询。
    }
  }

  Future<bool> select(String id) {
    final skin = AppSkin.byId(id);
    if (skin == null) return Future<bool>.value(false);
    final revision = ++_revision;
    _current = skin;
    notifyListeners();
    final operation = _pending.then((_) async {
      try {
        await _storage.saveAppSkinId(skin.id);
        _persisted = skin;
        return true;
      } catch (_) {
        if (revision == _revision) {
          _current = _persisted;
          notifyListeners();
        }
        return false;
      }
    });
    _pending = operation.then<void>((_) {});
    return operation;
  }
}
