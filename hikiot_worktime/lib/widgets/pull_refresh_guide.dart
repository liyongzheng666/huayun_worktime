import 'package:flutter/material.dart';
import '../core/theme/theme.dart';

/// 下拉刷新引导提示组件
/// 不遮挡页面，只显示浮动提示，让用户真正下拉刷新
class PullRefreshGuide extends StatefulWidget {
  final VoidCallback onCompleted;

  const PullRefreshGuide({super.key, required this.onCompleted});

  @override
  State<PullRefreshGuide> createState() => _PullRefreshGuideState();
}

class _PullRefreshGuideState extends State<PullRefreshGuide>
    with TickerProviderStateMixin {
  late AnimationController _bounceController;
  late AnimationController _pulseController;
  late Animation<double> _bounceAnimation;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // 弹跳动画 - 手指上下移动
    _bounceController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    // 脉冲动画 - 呼吸效果
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _bounceAnimation = Tween<double>(begin: 0, end: 40).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.easeInOut),
    );

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 循环播放
    _bounceController.repeat(reverse: true);
    _pulseController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _bounceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 仅装饰层穿透手势，按钮保留独立点击区域。
                Flexible(
                  flex: 3,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (context, child) => Transform.scale(
                        scale: _pulseAnimation.value,
                        child: child,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: constraints.maxWidth - 40,
                          child: _buildGuideCard(),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: IgnorePointer(
                    child: constraints.maxHeight < 450
                        ? const SizedBox.shrink()
                        : Center(
                            child: AnimatedBuilder(
                              animation: _bounceAnimation,
                              builder: (context, child) => Transform.translate(
                                offset: Offset(0, _bounceAnimation.value),
                                child: child,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.keyboard_double_arrow_down,
                                      size: 48,
                                      color: colors.primary,
                                    ),
                                    const SizedBox(height: 8),
                                    CircleAvatar(
                                      radius: 36,
                                      backgroundColor: colors.primary,
                                      child: Icon(
                                        Icons.touch_app,
                                        size: 40,
                                        color: colors.onPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: widget.onCompleted,
                  icon: const Icon(Icons.skip_next, size: 20),
                  label: const Text('我知道了'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.surface,
                    foregroundColor: colors.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    elevation: 8,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGuideCard() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppDimens.borderRadiusLg,
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.1),
              borderRadius: AppDimens.borderRadius,
            ),
            child: Icon(Icons.swipe_down, color: colors.primary, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '👋 欢迎使用！',
                  style: TextStyle(
                    fontSize: AppDimens.fontLg,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '向下拉动页面即可刷新数据',
                  style: TextStyle(
                    fontSize: AppDimens.fontMd,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
