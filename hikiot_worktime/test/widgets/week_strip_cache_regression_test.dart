import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/core/constants/storage_keys.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/services/work_log_repository.dart';
import 'package:hikiot_worktime/widgets/week_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('旧缓存待确认，查得正工时后切换日期仍已提交，仅明确零工时标红', (tester) async {
    SharedPreferences.setMockInitialValues({
      StorageKeys.bossHoursKey('2020-01'): '{}',
      StorageKeys.bossHoursRefreshedAtKey('2020-01'): DateTime.now()
          .toIso8601String(),
    });
    final storage = StorageService();
    await storage.saveTeamContext(teamNo: 'test');
    await storage.saveMonthlyData('test', '2020-01', {
      '2020-01-06': {'hours': 8.0},
      '2020-01-07': {'hours': 8.0},
    });
    final repository = WorkLogRepository(storage: storage);
    final key = GlobalKey<WeekStripState>();
    var selected = DateTime(2020, 1, 8);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return WeekStrip(
                key: key,
                selectedDate: selected,
                onDateSelected: (date) => setState(() => selected = date),
                loadWeek: repository.loadWeek,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    List<BoxDecoration> dots() => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(PageView),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .toList();

    expect(dots(), hasLength(2));
    expect(dots().every((d) => d.border != null), isTrue);
    expect(find.textContaining('提交状态未知'), findsOneWidget);

    await storage.saveBossHoursForDate('2020-01-06', 8);
    await storage.saveBossHoursForDate('2020-01-07', 0);
    key.currentState!.refresh();
    await tester.pumpAndSettle();
    const red = Color(0xFFE53935);
    expect(dots().where((d) => d.border == null), hasLength(2));
    expect(dots().where((d) => d.color == red), hasLength(1));

    // 选中已提交日，再切到其他日期；正工时状态不能退回红点。
    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2020, 1, 6));
    await tester.tap(find.text('9'));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2020, 1, 9));
    expect(dots().where((d) => d.border == null), hasLength(2));
    expect(dots().where((d) => d.color == red), hasLength(1));
    final week = await repository.loadWeek(selected);
    expect(week.first.isSubmitted, isTrue);
    expect(week[1].isSubmitted, isFalse);
  });
}
