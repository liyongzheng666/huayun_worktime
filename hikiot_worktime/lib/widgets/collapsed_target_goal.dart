import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/work_time_calculator.dart';

/// 已达成目标的折叠卡片
///
/// 每日工时页和月度统计页都要显示它，而且要求完全一致。原先两边各抄了一份
/// 逐字相同的实现，结果同一个渲染 BUG 在两个页面各犯一次——按项目「再一再而
/// 不再三」的规矩收口到这里，顺带让它能被单独测到（放在 State 的私有方法里
/// 是测不了的，而这个 BUG 恰恰只有渲染出来才看得见）。
///
/// **布局上有一条不能踩的线**：外层必须是 `Row`（负责「左边一坨、右边工时」
/// 的分栏），换行交给内层 `Wrap`。**不能把整体做成 `Wrap` 再塞个 `Spacer`
/// 把工时推到右边**——`Spacer` 本质是 `Expanded`，只能有 Flex 父级；放进
/// `Wrap` 会抛 `Incorrect use of ParentDataWidget`，整张卡片被替换成
/// `ErrorWidget`。而 **Release 构建下 `ErrorWidget` 就是一整块纯灰色**
/// （Debug 下才是红黄条纹），所以本地跑 Debug 根本看不出来，用户装了正式包
/// 才发现「目标进度整栏变成一块灰的」。已经实际发生过一次。
class CollapsedTargetGoal extends StatelessWidget {
  const CollapsedTargetGoal({
    super.key,
    required this.target,
    required this.currentHours,
    required this.targetHours,
    this.isBaseTarget = false,
    this.isPinned = false,
    this.onPinToggle,
  });

  /// 目标百分比，如 120
  final int target;

  final double currentHours;
  final double targetHours;

  /// 是否是基准目标，是则挂一个「基准」徽章
  final bool isBaseTarget;

  /// 是否被长按置顶
  final bool isPinned;

  /// 长按触发置顶切换；为空则不响应长按
  final VoidCallback? onPinToggle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 震动不 await：它是反馈，不是前置条件。await 在前面会把回调推迟到
      // 平台通道回来之后，置顶这种「点了要立刻见效」的动作不该等它。
      onLongPress: onPinToggle == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onPinToggle!();
            },
      child: Card(
        color: Colors.green[50],
        margin: const EdgeInsets.only(bottom: 8),
        shape: isPinned
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
                side: const BorderSide(color: Colors.amber, width: 2),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                // 字体放大时左边这一坨要能换行，否则会把右边的工时顶出屏幕
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 18,
                    ),
                    Text(
                      '$target% 目标已达成',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isBaseTarget) _badge(),
                    if (isPinned)
                      Icon(Icons.push_pin, size: 14, color: Colors.amber[700]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 右边这段也必须能让步。只把左边设成 Expanded 是不够的：
              // Expanded 分到的是「右边按自然宽度占完之后剩下的」，字体放大到
              // 两倍再遇上窄屏，光这段就比整行还宽，照样溢出（实测 280 宽 +
              // 2 倍字号溢出 86px）。给它 Flexible 并允许换行，挤不下就折行。
              Flexible(
                child: Text(
                  '${WorkTimeCalculator.formatHours(currentHours)}h'
                  ' / ${WorkTimeCalculator.formatHours(targetHours)}h',
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _badge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '基准',
        style: TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
