import 'package:flutter/material.dart';

import '../services/work_log_repository.dart';
import '../utils/date_helper.dart';
import '../utils/haptic_utils.dart';
import '../utils/work_time_calculator.dart';

/// 可左右滑动的周条
///
/// 取代原来「‹ 日期 ›」两个箭头的做法：箭头一次只能挪一天，而且看不出
/// 哪几天已经写过日志。周条一屏就是七天，滑动切周、点击切天。
///
/// 每天显示两行信息：
/// - 打卡工时（本地缓存里没有时显示 `--`，表示未同步而非零工时）
/// - 状态圆点：实心＝CSV 里有这天的日志，空心＝有工时但没写，无＝什么都没有
class WeekStrip extends StatefulWidget {
  const WeekStrip({
    super.key,
    required this.selectedDate,
    required this.onDateSelected,
    required this.loadWeek,
  });

  final DateTime selectedDate;

  /// 点某一天、或滑动切周落到新的一天时回调。
  final ValueChanged<DateTime> onDateSelected;

  /// 取某一周的概览，由外部注入便于测试。
  final Future<List<WorkLogDaySummary>> Function(DateTime anyDayInWeek)
  loadWeek;

  @override
  State<WeekStrip> createState() => WeekStripState();
}

class WeekStripState extends State<WeekStrip> {
  /// PageView 的中点。周是无限的，用一个足够大的基准页号往两边算偏移，
  /// 比动态往列表两头插数据简单得多。
  static const int _basePage = 10000;

  late final PageController _controller;

  /// 基准周的周一，其余页按与它相差的周数推算
  late DateTime _baseMonday;

  final Map<String, List<WorkLogDaySummary>> _cache = {};

  @override
  void initState() {
    super.initState();
    _baseMonday = _mondayOf(widget.selectedDate);
    _controller = PageController(initialPage: _basePage);
    _ensureLoaded(_baseMonday);
  }

  @override
  void didUpdateWidget(covariant WeekStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSameDay(oldWidget.selectedDate, widget.selectedDate)) {
      // 外部改了日期（例如导入后重新加载），若跨了周就把页面滑过去
      final target = _mondayOf(widget.selectedDate);
      final delta = target.difference(_baseMonday).inDays ~/ 7;
      final page = _basePage + delta;
      if (_controller.hasClients && _controller.page?.round() != page) {
        _controller.jumpToPage(page);
      }
      _ensureLoaded(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static DateTime _mondayOf(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime _mondayForPage(int page) =>
      _baseMonday.add(Duration(days: (page - _basePage) * 7));

  Future<void> _ensureLoaded(DateTime monday) async {
    final key = DateHelper.formatDate(monday);
    if (_cache.containsKey(key)) return;

    final days = await widget.loadWeek(monday);
    if (!mounted) return;
    setState(() => _cache[key] = days);
  }

  /// 刷新已缓存的周，供外部在数据变化后调用。
  void refresh() {
    _cache.clear();
    _ensureLoaded(_mondayOf(widget.selectedDate));
  }

  void _onPageChanged(int page) {
    final monday = _mondayForPage(page);
    _ensureLoaded(monday);

    // 滑到新的一周时，选中同一个星期几——保持「星期三翻到上星期三」的直觉
    final weekdayOffset = widget.selectedDate.weekday - 1;
    widget.onDateSelected(monday.add(Duration(days: weekdayOffset)));
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: PageView.builder(
                controller: _controller,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, page) {
                  final monday = _mondayForPage(page);
                  final days = _cache[DateHelper.formatDate(monday)];
                  return _buildWeek(monday, days);
                },
              ),
            ),
            _buildLegend(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final monday = _mondayOf(widget.selectedDate);
    final sunday = monday.add(const Duration(days: 6));
    final isThisWeek = _isSameDay(monday, _mondayOf(DateHelper.getWorkDate()));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(Icons.calendar_today, size: 18, color: Colors.blue[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${monday.month}月${monday.day}日 - ${sunday.month}月${sunday.day}日',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey[800],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 翻走之后要有一键回到本周的路，否则滑远了很难找回来
          if (!isThisWeek)
            TextButton(
              onPressed: () {
                HapticUtils.selectionClick();
                widget.onDateSelected(DateHelper.getWorkDate());
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('本周', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _buildWeek(DateTime monday, List<WorkLogDaySummary>? days) {
    const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

    return Row(
      children: List.generate(7, (i) {
        final date = monday.add(Duration(days: i));
        final summary = days == null || i >= days.length ? null : days[i];
        return Expanded(
          child: _buildDay(date, weekdayNames[i], summary),
        );
      }),
    );
  }

  Widget _buildDay(DateTime date, String weekday, WorkLogDaySummary? summary) {
    final isSelected = _isSameDay(date, widget.selectedDate);
    final isToday = _isSameDay(date, DateHelper.getWorkDate());
    final isWeekend = date.weekday >= 6;

    final Color textColor;
    if (isSelected) {
      textColor = Colors.white;
    } else if (isWeekend) {
      textColor = Colors.grey[500]!;
    } else {
      textColor = Colors.grey[850]!;
    }

    return InkWell(
      // 不 await 触感：它只是副作用，让它挡在选中日期前面会平白多出一个
      // 异步间隙，用户点了要等一下才响应
      onTap: () {
        HapticUtils.selectionClick();
        widget.onDateSelected(date);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[700] : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          // 今天但未选中时用描边标出，不跟选中态抢视觉
          border: !isSelected && isToday
              ? Border.all(color: Colors.blue[700]!, width: 1.5)
              : null,
        ),
        // 整格内容随字体放大而变高，而 PageView 高度是固定的。
        // 用 FittedBox 让内容整体缩放，避免任何字号下溢出。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              weekday,
              style: TextStyle(
                fontSize: 11,
                color: isSelected ? Colors.white70 : Colors.grey[500],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 16,
                height: 1.1,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 2),
            // 工时最长是「11.10」，窄屏上宁可缩小也不能被裁掉
            SizedBox(
              height: 12,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  summary != null && summary.hasHours
                      ? WorkTimeCalculator.formatHours(summary.hours!)
                      : '--',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.0,
                    color: isSelected
                        ? Colors.white
                        : textColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            _buildStatusDot(summary, isSelected),
          ],
          ),
        ),
      ),
    );
  }

  /// 提交状态点。
  ///
  /// **这个点回答的是「这天提交了没有」，不是「CSV 里有没有素材」。**
  /// 早期版本按 CSV 有无着色，结果导入一次 CSV 整月立刻全是实心点，
  /// 看着像全都提交完了，实际一条都没提交——这是本页最容易误导人的地方。
  ///
  /// 四种状态，与月历页的 BOSS 状态条同一套语义：
  /// - 实心中性色 → 已提交到 BOSS
  /// - 红色实心   → 已过去、当天有打卡，却还没提交，是真正的欠账
  /// - 空心蓝     → 素材已就绪（CSV 里有），等着提交
  /// - 不显示     → 这天没有任何相关数据
  Widget _buildStatusDot(WorkLogDaySummary? summary, bool isSelected) {
    if (summary == null) return const SizedBox(height: 8);

    final isPast = _isPast(summary.date);

    if (summary.isSubmitted) {
      return _dot(
        fill: isSelected ? Colors.white : Colors.grey.shade500,
        filled: true,
      );
    }
    if (isPast && summary.hasHours) {
      return _dot(
        fill: isSelected ? Colors.white : _overdueColor,
        filled: true,
      );
    }
    if (summary.hasEntry) {
      return _dot(
        fill: isSelected ? Colors.white : Colors.blue.shade700,
        filled: false,
      );
    }
    return const SizedBox(height: 8);
  }

  /// 已过期未提交的警示色，与月历页保持一致。
  static const Color _overdueColor = Color(0xFFE53935);

  static bool _isPast(DateTime date) {
    final today = DateHelper.getWorkDate();
    return DateTime(
      date.year,
      date.month,
      date.day,
    ).isBefore(DateTime(today.year, today.month, today.day));
  }

  Widget _dot({required Color fill, required bool filled}) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? fill : Colors.transparent,
        border: filled ? null : Border.all(color: fill, width: 1.2),
      ),
    );
  }

  /// 状态点的图例。自造的符号不解释没人看得懂，
  /// 与月历页一样把符号本身画出来，而不是只用文字描述。
  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 14, right: 14),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          _legendItem(_dot(fill: Colors.grey.shade500, filled: true), '已提交'),
          _legendItem(_dot(fill: _overdueColor, filled: true), '待补交'),
          _legendItem(
            _dot(fill: Colors.blue.shade700, filled: false),
            '素材已就绪',
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Widget sample, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        sample,
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
      ],
    );
  }
}
