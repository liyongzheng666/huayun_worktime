import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_skin.dart';
import '../services/app_theme_controller.dart';
import '../utils/haptic_utils.dart';

class ThemeSelectionScreen extends StatelessWidget {
  const ThemeSelectionScreen({super.key, this.controller});
  final AppThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final themes = controller ?? AppThemeController.shared;
    return AnimatedBuilder(
      animation: themes,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('外观与主题')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选一种今天喜欢的颜色',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '每种风格，都属于每个人。轻点切换，自动记住。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              LayoutBuilder(
                builder: (context, constraints) {
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  final columns = constraints.maxWidth < 320 || largeText
                      ? 1
                      : 2;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final skin in AppSkin.all)
                        SizedBox(
                          width: width,
                          child: _SkinTile(
                            skin: skin,
                            selected: themes.current.id == skin.id,
                            onTap: () async {
                              if (themes.current.id == skin.id) return;
                              unawaited(HapticUtils.selectionClick());
                              final saved = await themes.select(skin.id);
                              if (!saved && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('这次没能记住主题，已恢复原来的选择，请再试一次。'),
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkinTile extends StatelessWidget {
  const _SkinTile({
    required this.skin,
    required this.selected,
    required this.onTap,
  });
  final AppSkin skin;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${skin.name}主题',
      child: Material(
        color: skin.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? skin.accent : skin.ink.withValues(alpha: 0.16),
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('skin-${skin.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    height: 94,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: skin.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(width: 28, height: 5, color: skin.accent),
                        const SizedBox(height: 12),
                        Container(
                          width: 65,
                          height: 7,
                          color: skin.ink.withValues(alpha: 0.65),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 4,
                          color: skin.ink.withValues(alpha: 0.13),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle_outline,
                              size: 15,
                              color: skin.accent,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Container(
                                height: 4,
                                color: skin.ink.withValues(alpha: 0.20),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        skin.name,
                        style: TextStyle(
                          color: skin.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check_circle, color: skin.accent, size: 20),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  skin.description,
                  style: TextStyle(
                    color: skin.ink.withValues(alpha: 0.74),
                    fontSize: 12,
                  ),
                ),
                if (selected)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '当前使用',
                      style: TextStyle(color: skin.accent, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
