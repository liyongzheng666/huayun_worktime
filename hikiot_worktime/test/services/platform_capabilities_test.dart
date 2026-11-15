import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/platform_capabilities.dart';

void main() {
  tearDown(() {
    PlatformCapabilities.debugOverride = null;
  });

  group('PlatformCapabilities', () {
    test('Android 共用工作台，同时保留后台闹钟和实时提醒能力', () {
      PlatformCapabilities.debugOverride =
          const PlatformCapabilitiesOverride.android();

      expect(PlatformCapabilities.supportsExactBackgroundAlarm, isTrue);
      expect(PlatformCapabilities.supportsLiveReminderContent, isTrue);
      expect(PlatformCapabilities.needsExactAlarmPermission, isTrue);
      expect(PlatformCapabilities.needsVendorKeepAliveGuide, isTrue);
      expect(PlatformCapabilities.supportsTodayWrapUp, isTrue);
    });

    test('iOS 无后台闹钟能力，提醒只能推固定文案且不需要保活引导', () {
      PlatformCapabilities.debugOverride =
          const PlatformCapabilitiesOverride.ios();

      expect(PlatformCapabilities.supportsExactBackgroundAlarm, isFalse);
      expect(PlatformCapabilities.supportsLiveReminderContent, isFalse);
      expect(PlatformCapabilities.needsExactAlarmPermission, isFalse);
      expect(PlatformCapabilities.needsVendorKeepAliveGuide, isFalse);
      expect(PlatformCapabilities.supportsTodayWrapUp, isTrue);
    });
  });
}
