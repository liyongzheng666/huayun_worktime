import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/theme/app_skin.dart';
import 'package:hikiot_worktime/services/app_theme_controller.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControlledStorage extends StorageService {
  String? savedId;
  final savedIds = <String>[];
  Completer<void>? gate;
  final failIds = <String>{};
  bool failReads = false;

  @override
  Future<String?> loadAppSkinId() async {
    if (failReads) throw StateError('不可读');
    return savedId;
  }

  @override
  Future<void> saveAppSkinId(String id) async {
    savedIds.add(id);
    await gate?.future;
    if (failIds.contains(id)) throw StateError('不可写');
    savedId = id;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全部主题ID稳定且唯一，青草为默认值', () {
    expect(AppSkin.all.map((skin) => skin.id), [
      'forest',
      'graphite',
      'paper',
      'blue',
      'rose',
      'apricot',
      'lavender',
      'grass',
    ]);
    expect(AppThemeController().current.id, 'grass');
  });

  test('真实设置存储重建控制器仍保留主题及原设置', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.saveSettings({
      'display_name': '小林',
      'targets': [160, 180],
    });
    final controller = AppThemeController(storage: storage);
    await controller.load();
    expect(await controller.select('rose'), isTrue);
    await storage.saveSettings({
      'display_name': '小林',
      'targets': [170, 190],
    });
    final restarted = AppThemeController(storage: storage);
    await restarted.load();
    expect(restarted.current.id, 'rose');
    final settings = await storage.loadSettings();
    expect(settings['display_name'], '小林');
    expect(settings['targets'], [170, 190]);
    expect(settings.containsKey('ios_app_skin'), isFalse);
  });

  test('未知或错误类型存储值回退青草，非法选择不写入', () async {
    for (final id in ['removed-theme', 42, null]) {
      SharedPreferences.setMockInitialValues({'ios_app_skin': ?id});
      final storage = StorageService();
      final controller = AppThemeController(storage: storage);
      await controller.load();
      expect(controller.current.id, 'grass');
      expect(await controller.select('invalid'), isFalse);
      expect((await SharedPreferences.getInstance()).get('ios_app_skin'), id);
    }
  });

  test('读取失败不影响默认主题和启动', () async {
    final storage = _ControlledStorage()..failReads = true;
    final controller = AppThemeController(storage: storage);
    await controller.load();
    expect(controller.current.id, 'grass');
    storage.failIds.add('rose');
    expect(await controller.select('rose'), isFalse);
    expect(controller.current.id, 'grass');
  });

  test('快速选择即时更新但按选择顺序保存', () async {
    final storage = _ControlledStorage()..gate = Completer<void>();
    final controller = AppThemeController(storage: storage);
    final first = controller.select('graphite');
    final second = controller.select('rose');
    final third = controller.select('lavender');
    expect(controller.current.id, 'lavender');
    await Future<void>.delayed(Duration.zero);
    expect(storage.savedIds, ['graphite']);
    storage.gate!.complete();
    expect(await Future.wait([first, second, third]), [true, true, true]);
    expect(storage.savedIds, ['graphite', 'rose', 'lavender']);
    expect(storage.savedId, 'lavender');
  });

  test('末次选择保存失败，恢复此前成功持久化的选择', () async {
    final storage = _ControlledStorage()..failIds.add('rose');
    final controller = AppThemeController(storage: storage);
    final first = controller.select('graphite');
    final second = controller.select('rose');
    expect(controller.current.id, 'rose');
    expect(await first, isTrue);
    expect(await second, isFalse);
    expect(controller.current.id, 'graphite');
    expect(storage.savedId, 'graphite');
    expect(await controller.select('grass'), isTrue);
  });

  test('早先选择失败不能覆盖更新的选择', () async {
    final storage = _ControlledStorage()..failIds.add('rose');
    final controller = AppThemeController(storage: storage);
    final first = controller.select('rose');
    final second = controller.select('apricot');
    expect(await first, isFalse);
    expect(controller.current.id, 'apricot');
    expect(await second, isTrue);
  });
}
