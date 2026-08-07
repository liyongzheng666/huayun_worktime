import 'package:flutter/material.dart';

import '../core/constants/constants.dart';
import '../utils/work_time_calculator.dart';

/// 工时完成度胶囊
///
/// 配色按「今天干得够不够 / 是不是干过头了」分三档：
/// - 不到 100%  → 橙，还没到标准工时
/// - 100%~140% → 绿，正常区间
/// - 超过 140%  → 红并闪烁，提示今天已经明显超时
///
/// 红色之所以要闪，是因为超时这件事光靠静态颜色容易被忽略——
/// 前两档本来就有颜色，多一个红色未必能引起注意。
class PercentagePill extends StatefulWidget {
  const PercentagePill({super.key, required this.percentage});

  final double percentage;

  /// 百分比对应的颜色。
  ///
  /// 做成静态方法是为了让同一行的工时数字复用同一套配色——
  /// 数字和胶囊颜色不一致会让人以为是两回事。
  static Color colorFor(double percentage) {
    if (isOverwork(percentage)) return const Color(0xFFD32F2F); // 红
    if (percentage >= AppConstants.standardWorkPercent) {
      return const Color(0xFF2E7D32); // 绿
    }
    return const Color(0xFFEF6C00); // 橙
  }

  /// 是否已超时到需要闪烁提醒的程度。
  static bool isOverwork(double percentage) =>
      percentage > AppConstants.overworkPercent;

  @override
  State<PercentagePill> createState() => _PercentagePillState();
}

class _PercentagePillState extends State<PercentagePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant PercentagePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工时是随时间增长的，可能在页面存续期间跨过阈值
    if (PercentagePill.isOverwork(widget.percentage) !=
        PercentagePill.isOverwork(oldWidget.percentage)) {
      _syncAnimation();
    }
  }

  /// 只在超时时才跑动画：没必要为一个静态胶囊常驻一个 ticker。
  void _syncAnimation() {
    if (PercentagePill.isOverwork(widget.percentage)) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = PercentagePill.colorFor(widget.percentage);
    final text = '${WorkTimeCalculator.formatHours(widget.percentage)}%';

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );

    if (!PercentagePill.isOverwork(widget.percentage)) return pill;

    // 闪烁用透明度往复，而不是整块隐藏——
    // 整块消失会让这一行的高度和位置来回跳，看着像故障。
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.35).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: pill,
    );
  }
}
