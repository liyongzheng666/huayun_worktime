import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await HapticUtils.setMode(HapticMode.advanced);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('iOS 高级模式调用真实的轻触和选择系统通道', () async {
    await HapticUtils.lightImpact();
    await HapticUtils.selectionClick();
    expect(calls.map((call) => call.method), [
      'HapticFeedback.vibrate',
      'HapticFeedback.vibrate',
    ]);
    expect(calls.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.selectionClick',
    ]);
  });

  test('iOS 基础模式仍有选择反馈，Android 保留简化策略', () async {
    await HapticUtils.setMode(HapticMode.basic);
    await HapticUtils.selectionClick();
    expect(calls.single.method, 'HapticFeedback.vibrate');
    expect(calls.single.arguments, 'HapticFeedbackType.selectionClick');
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await HapticUtils.selectionClick();
    expect(calls, isEmpty);
  });

  test('关闭震动后点击、选择、刷新和按压均不调用系统通道', () async {
    await HapticUtils.setMode(HapticMode.off);
    await HapticUtils.lightImpact();
    await HapticUtils.selectionClick();
    await HapticUtils.mediumImpact();
    await HapticUtils.heavyImpact();
    await HapticUtils.vibrate();
    await HapticUtils.homeButtonPress();
    await HapticUtils.pullRefreshCharging();
    await HapticUtils.pullRefreshThreshold();
    await HapticUtils.pullRefreshRelease();
    await HapticUtils.pullRefreshComplete();
    expect(calls, isEmpty);
  });

  test('存储中的关闭选项在重新初始化后仍生效', () async {
    await HapticUtils.setMode(HapticMode.off);
    await HapticUtils.init();
    await HapticUtils.selectionClick();
    expect(HapticUtils.mode, HapticMode.off);
    expect(calls, isEmpty);
  });
}
