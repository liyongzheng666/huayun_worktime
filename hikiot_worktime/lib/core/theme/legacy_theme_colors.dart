import 'package:flutter/material.dart';

import '../../services/platform_capabilities.dart';

/// 旧页面逐步接入 iOS 皮肤；Android 继续使用调用处原有的配色。
class LegacyThemeColors {
  LegacyThemeColors._();

  static Color _pick(
    BuildContext context,
    Color fallback,
    Color Function(ColorScheme) resolve,
  ) {
    final theme = Theme.of(context);
    return PlatformCapabilities.supportsTodayWrapUp
        ? resolve(theme.colorScheme)
        : fallback;
  }

  static Color text(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.onSurface);
  static Color muted(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.onSurfaceVariant);
  static Color surface(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.surfaceContainerLow);
  static Color inset(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.surfaceContainerHighest);
  static Color border(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.outlineVariant);
  static Color primary(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.primary);
  static Color onPrimary(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.onPrimary);
  static Color primaryContainer(BuildContext context, Color fallback) =>
      _pick(context, fallback, (scheme) => scheme.primaryContainer);

  /// 警告等语义色保留，仅将深色模式下的浅底改为对应的淡色覆盖。
  static Color panel(BuildContext context, Color fallback) {
    final theme = Theme.of(context);
    if (!PlatformCapabilities.supportsTodayWrapUp ||
        theme.brightness != Brightness.dark) {
      return fallback;
    }
    return Color.alphaBlend(
      fallback.withValues(alpha: 0.12),
      theme.colorScheme.surface,
    );
  }
}
