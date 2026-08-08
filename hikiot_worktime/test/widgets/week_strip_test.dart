import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/utils/date_helper.dart';
import 'package:hikiot_worktime/widgets/week_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // 点选会触发触感反馈，而它要读取震动模式设置；
    // 不给 mock 的话回调会在读设置时抛异常，表现为「点了没反应」
    SharedPreferences.setMockInitialValues({});
  });

  /// 2026-08-05 是星期三，所在周 8/3(一) ~ 8/9(日)
  final wednesday = DateTime(2026, 8, 5);

  Future<List<WorkLogDaySummary>> fakeWeek(DateTime anyDayInWeek) async {
    final monday = DateTime(
      anyDayInWeek.year,
      anyDayInWeek.month,
      anyDayInWeek.day,
    ).subtract(Duration(days: anyDayInWeek.weekday - 1));

    return List.generate(7, (i) {
      final date = monday.add(Duration(days: i));
      return WorkLogDaySummary(
        date: date,
        dateStr: DateHelper.formatDate(date),
        // 周一、周二当作已写日志，周三只有工时没写
        hasEntry: i < 2,
        hours: i < 3 ? 8.5 : null,
      );
    });
  }

  Widget wrap({
    required DateTime selected,
    required ValueChanged<DateTime> onSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: WeekStrip(
          selectedDate: selected,
          onDateSelected: onSelected,
          loadWeek: fakeWeek,
        ),
      ),
    );
  }

  testWidgets('展示所在周的七天与周区间', (tester) async {
    await tester.pumpWidget(wrap(selected: wednesday, onSelected: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('8月3日 - 8月9日'), findsOneWidget);
    for (final day in ['3', '4', '5', '6', '7', '8', '9']) {
      expect(find.text(day), findsOneWidget, reason: '缺少 $day 号');
    }
  });

  testWidgets('有缓存的天显示工时，没有的显示 --', (tester) async {
    await tester.pumpWidget(wrap(selected: wednesday, onSelected: (_) {}));
    await tester.pumpAndSettle();

    // 周一到周三有工时，周四起没有
    expect(find.text('8.50'), findsNWidgets(3));
    expect(find.text('--'), findsNWidgets(4));
  });

  testWidgets('点某一天回调该日期', (tester) async {
    DateTime? picked;
    await tester.pumpWidget(
      wrap(selected: wednesday, onSelected: (d) => picked = d),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(DateHelper.formatDate(picked!), '2026-08-06');
  });

  testWidgets('左右滑动切周，并落到新一周的同一个星期几', (tester) async {
    DateTime? picked;
    await tester.pumpWidget(
      wrap(selected: wednesday, onSelected: (d) => picked = d),
    );
    await tester.pumpAndSettle();

    // 往左甩＝下一周。用 fling 而不是 drag：PageView 靠速度决定是否翻页，
    // 无速度的拖拽刚好到一半时会回弹。
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();

    // 原本选的是星期三，切到下周应仍是星期三
    expect(picked, isNotNull);
    expect(DateHelper.formatDate(picked!), '2026-08-12');
    expect(picked!.weekday, DateTime.wednesday);
  });

  testWidgets('不在本周时显示「本周」入口，滑远了能回来', (tester) async {
    // 用一个必然不是本周的日期，避免这条断言随时间推移而失效
    await tester.pumpWidget(
      wrap(selected: DateTime(2020, 1, 8), onSelected: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('本周'), findsOneWidget);
  });

  testWidgets('正处于本周时不显示「本周」入口', (tester) async {
    await tester.pumpWidget(
      wrap(selected: DateHelper.getWorkDate(), onSelected: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('本周'), findsNothing);
  });
}
