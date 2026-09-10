import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/app_theme_controller.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final persisted = <String, Object>{};
  var failWrite = false;
  var throwWrite = false;

  setUp(() {
    SharedPreferences.resetStatic();
    persisted.clear();
    failWrite = false;
    throwWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll' ||
              call.method == 'getAllWithParameters') {
            return Map<String, Object>.of(persisted);
          }
          if (call.method == 'setString') {
            if (throwWrite) throw PlatformException(code: 'disk_unavailable');
            if (failWrite) return false;
            final args = call.arguments as Map;
            persisted[args['key'] as String] = args['value'] as String;
            return true;
          }
          throw StateError('意外的平台调用：${call.method}');
        });
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('主题独立写入原生键并可重新加载', () async {
    final storage = StorageService();
    await storage.saveAppSkinId('grass');
    expect(persisted, {'flutter.ios_app_skin': 'grass'});
    SharedPreferences.resetStatic();
    expect(await storage.loadAppSkinId(), 'grass');
  });

  test('原生写入返回false时回滚界面与插件缓存', () async {
    final storage = StorageService();
    await storage.saveAppSkinId('graphite');
    final controller = AppThemeController(storage: storage);
    await controller.load();
    failWrite = true;
    expect(await controller.select('rose'), isFalse);
    expect(controller.current.id, 'graphite');
    expect(await storage.loadAppSkinId(), 'graphite');
    expect(persisted['flutter.ios_app_skin'], 'graphite');
    failWrite = false;
    expect(await controller.select('grass'), isTrue);
    expect(await storage.loadAppSkinId(), 'grass');
  });

  test('原生写入抛出异常时回滚缓存并保留已保存主题', () async {
    final storage = StorageService();
    await storage.saveAppSkinId('lavender');
    throwWrite = true;
    await expectLater(
      storage.saveAppSkinId('rose'),
      throwsA(isA<PlatformException>()),
    );
    expect(await storage.loadAppSkinId(), 'lavender');
  });
}
