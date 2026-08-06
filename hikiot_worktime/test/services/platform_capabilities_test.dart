import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';

void main() {
  tearDown(() {
    PlatformCapabilities.debugOverride = null;
  });

  group('PlatformCapabilities', () {
    test('Android 具备后台闹钟能力，因此提醒文案可携带实时打卡状态', () {
      PlatformCapabilities.debugOverride =
          const PlatformCapabilitiesOverride.android();

      expect(PlatformCapabilities.supportsExactBackgroundAlarm, isTrue);
      expect(PlatformCapabilities.supportsLiveReminderContent, isTrue);
      expect(PlatformCapabilities.needsExactAlarmPermission, isTrue);
      expect(PlatformCapabilities.needsVendorKeepAliveGuide, isTrue);
    });

    test('iOS 无后台闹钟能力，提醒只能推固定文案且不需要保活引导', () {
      PlatformCapabilities.debugOverride =
          const PlatformCapabilitiesOverride.ios();

      expect(PlatformCapabilities.supportsExactBackgroundAlarm, isFalse);
      expect(PlatformCapabilities.supportsLiveReminderContent, isFalse);
      expect(PlatformCapabilities.needsExactAlarmPermission, isFalse);
      expect(PlatformCapabilities.needsVendorKeepAliveGuide, isFalse);
    });
  });
}
