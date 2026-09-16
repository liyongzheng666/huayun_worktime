import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/team_selection_dialog.dart';

void main() {
  group('TeamSelectionDialog', () {
    for (final canCancel in [false, true]) {
      testWidgets(canCancel ? '允许取消时保留系统返回' : '首次必选团队时系统返回不能跳过选择', (
        tester,
      ) async {
        var returned = false;
        Map<String, dynamic>? selectedTeam;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selectedTeam = await TeamSelectionDialog.show(
                    context,
                    teams: _teams(),
                    showCancel: canCancel,
                  );
                  returned = true;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(returned, canCancel);
        if (canCancel) {
          expect(find.text('选择团队'), findsNothing);
          expect(selectedTeam, isNull);
        } else {
          expect(find.text('选择团队'), findsOneWidget);
          await tester.tap(find.text('一队'));
          await tester.pumpAndSettle();
          expect(returned, isTrue);
          expect(selectedTeam?['teamNo'], 'team-1');
        }
      });
    }

    testWidgets('returns selected team and marks current team', (tester) async {
      Map<String, dynamic>? selectedTeam;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  selectedTeam = await TeamSelectionDialog.show(
                    context,
                    teams: _teams(),
                    currentTeamNo: 'team-2',
                    showCancel: true,
                    barrierDismissible: true,
                  );
                },
                child: const Text('打开'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('选择团队'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.tap(find.text('一队'));
      await tester.pumpAndSettle();

      expect(selectedTeam?['teamNo'], 'team-1');
    });

    testWidgets('returns null when cancel is enabled and tapped', (
      tester,
    ) async {
      Map<String, dynamic>? selectedTeam = {'teamNo': 'initial'};

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  selectedTeam = await TeamSelectionDialog.show(
                    context,
                    teams: _teams(),
                    showCancel: true,
                    barrierDismissible: true,
                  );
                },
                child: const Text('打开'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(selectedTeam, isNull);
    });
  });
}

List<Map<String, dynamic>> _teams() {
  return [
    {'teamNo': 'team-1', 'teamName': '一队'},
    {'teamNo': 'team-2', 'teamName': '二队'},
  ];
}
