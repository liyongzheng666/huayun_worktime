import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/widgets/boss_login_dialog.dart';

class Answer {
  BossLoginRequest? value;
}

Future<Answer> pumpDialog(
  WidgetTester tester, {
  String initialUserName = '',
  bool hasRememberedPassword = false,
}) async {
  final answer = Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await BossLoginDialog.show(
              context: context,
              initialUserName: initialUserName,
              hasRememberedPassword: hasRememberedPassword,
            );
          },
          child: const Text('打开'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('明确说明后台登录与本机系统安全存储', (tester) async {
    await pumpDialog(tester);

    expect(find.text('登录将在后台完成，不会打开 BOSS 页面。'), findsOneWidget);
    expect(find.textContaining('本机系统安全存储'), findsOneWidget);
    expect(find.text('记住密码并自动登录'), findsOneWidget);
  });

  testWidgets('账号和密码缺一时不能提交', (tester) async {
    await pumpDialog(tester);
    final fields = find.byType(TextField);

    await tester.enterText(fields.at(0), 'user');
    await tester.pump();
    var button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '后台登录'),
    );
    expect(button.onPressed, isNull);

    await tester.enterText(fields.at(1), 'password');
    await tester.pump();
    button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '后台登录'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('成功回传凭据，但默认隐藏密码', (tester) async {
    final answer = await pumpDialog(tester, initialUserName: 'remembered-user');

    final passwordField = tester.widget<TextField>(
      find.byType(TextField).at(1),
    );
    expect(passwordField.obscureText, isTrue);
    await tester.enterText(find.byType(TextField).at(1), 'one-time-password');
    await tester.pump();
    final loginButton = find.widgetWithText(FilledButton, '后台登录');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(answer.value?.userName, 'remembered-user');
    expect(answer.value?.password, 'one-time-password');
    expect(answer.value?.openWeb, isFalse);
    expect(answer.value?.rememberPassword, isTrue);
  });

  testWidgets('可取消记住密码，仅执行本次登录', (tester) async {
    final answer = await pumpDialog(tester, initialUserName: 'user');
    await tester.enterText(find.byType(TextField).at(1), 'test-password');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('后台登录'));
    await tester.pumpAndSettle();
    expect(answer.value?.rememberPassword, isFalse);
  });

  testWidgets('已有记住的密码时提供明确清除入口', (tester) async {
    final answer = await pumpDialog(tester, hasRememberedPassword: true);
    await tester.tap(find.text('清除记住的密码'));
    await tester.pumpAndSettle();
    expect(answer.value?.forgetCredentials, isTrue);
    expect(answer.value?.password, isEmpty);
  });

  testWidgets('始终保留网页登录兜底', (tester) async {
    final answer = await pumpDialog(tester);
    await tester.tap(find.text('网页登录'));
    await tester.pumpAndSettle();

    expect(answer.value?.openWeb, isTrue);
    expect(answer.value?.password, isEmpty);
  });
}
