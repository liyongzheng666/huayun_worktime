import 'package:flutter/material.dart';

/// iOS 工作台共享布局的配色；风格名称不限定使用者。
@immutable
class AppSkin {
  const AppSkin({
    required this.id,
    required this.name,
    required this.description,
    required this.background,
    required this.surface,
    required this.accent,
    required this.ink,
    this.brightness = Brightness.light,
  });

  final String id;
  final String name;
  final String description;
  final Color background;
  final Color surface;
  final Color accent;
  final Color ink;
  final Brightness brightness;

  static const grass = AppSkin(
    id: 'grass',
    name: '青草',
    description: '柔白 · 清新草绿',
    background: Color(0xFFFAFDF5),
    surface: Color(0xFFEEF5E4),
    accent: Color(0xFF4C7B2E),
    ink: Color(0xFF293C24),
  );
  static const defaultSkin = grass;
  static const all = <AppSkin>[
    AppSkin(
      id: 'forest',
      name: '森林',
      description: '浅灰白 · 森林绿',
      background: Color(0xFFF9FAF8),
      surface: Color(0xFFEEF2EC),
      accent: Color(0xFF2D654C),
      ink: Color(0xFF252B28),
    ),
    AppSkin(
      id: 'graphite',
      name: '石墨',
      description: '石墨黑 · 暖金',
      background: Color(0xFF242821),
      surface: Color(0xFF30362C),
      accent: Color(0xFFD6AE60),
      ink: Color(0xFFF1F0E7),
      brightness: Brightness.dark,
    ),
    AppSkin(
      id: 'paper',
      name: '纸白',
      description: '纸白 · 墨绿',
      background: Color(0xFFF8F9F5),
      surface: Color(0xFFEEEFE7),
      accent: Color(0xFF45694E),
      ink: Color(0xFF2D3932),
    ),
    AppSkin(
      id: 'blue',
      name: '晴空',
      description: '冰白 · 晴空蓝',
      background: Color(0xFFFFFFFF),
      surface: Color(0xFFF5F7FA),
      accent: Color(0xFF285FE5),
      ink: Color(0xFF172234),
    ),
    AppSkin(
      id: 'rose',
      name: '玫瑰燕麦',
      description: '暖白 · 豆沙玫瑰',
      background: Color(0xFFFFFBFC),
      surface: Color(0xFFF7EEF1),
      accent: Color(0xFF9C526D),
      ink: Color(0xFF403139),
    ),
    AppSkin(
      id: 'apricot',
      name: '奶油杏',
      description: '奶油白 · 杏茶棕',
      background: Color(0xFFFFFCF6),
      surface: Color(0xFFF5EFE4),
      accent: Color(0xFF90633D),
      ink: Color(0xFF41372D),
    ),
    AppSkin(
      id: 'lavender',
      name: '雾紫',
      description: '月白 · 灰调薰衣草',
      background: Color(0xFFFDFBFF),
      surface: Color(0xFFF1EEF7),
      accent: Color(0xFF705A8D),
      ink: Color(0xFF393447),
    ),
    grass,
  ];

  static AppSkin? byId(String? id) {
    for (final skin in all) {
      if (skin.id == id) return skin;
    }
    return null;
  }

  ThemeData get themeData {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: dark ? background : Colors.white,
          surface: background,
          onSurface: ink,
          surfaceContainerLowest: background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: surface,
          surfaceContainerHighest: surface,
          onSurfaceVariant: ink.withValues(alpha: 0.74),
          outline: ink.withValues(alpha: 0.35),
          outlineVariant: ink.withValues(alpha: 0.13),
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      canvasColor: background,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: dark ? 0.22 : 0.10),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? accent
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: background,
        selectedItemColor: accent,
        unselectedItemColor: scheme.onSurfaceVariant,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
