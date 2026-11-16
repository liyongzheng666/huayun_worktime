import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hikiot_worktime/services/attendance_photo_loader.dart';
import 'package:hikiot_worktime/widgets/attendance_photo_dialog.dart';
import 'package:hikiot_worktime/widgets/attendance_photos_section.dart';

import '../services/attendance_photo_loader_test.dart' show photoPng;

void main() {
  for (final reverse in [false, true]) {
    testWidgets('两张真实解码图片依次弹出均成功，反向=$reverse，重看不再下载', (tester) async {
      final requests = <String>[];
      var saves = 0;
      const gallery = MethodChannel('gal');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(gallery, (
        call,
      ) async {
        if (call.method == 'hasAccess' || call.method == 'requestAccess') {
          return true;
        }
        if (call.method == 'putImageBytes') {
          expect(call.arguments['bytes'], photoPng);
          saves++;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          gallery,
          null,
        ),
      );
      final loader = AttendancePhotoLoader(
        createClient: () {
          var used = false;
          return MockClient((request) async {
            // 模拟真实服务器：复用同一客户端的第二次请求一直不返回。
            if (used) return Completer<http.Response>().future;
            used = true;
            requests.add(request.url.path);
            return http.Response.bytes(photoPng, 200);
          });
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    content: AttendancePhotosSection(
                      date: '2026-11-02',
                      dayData: const {
                        'checkInPhotoUrl': 'https://example.test/in',
                        'checkOutPhotoUrl': 'https://example.test/out',
                      },
                      loadPhotos: (_) async => throw StateError('已有地址禁止重查考勤'),
                      photoLoader: loader,
                    ),
                  ),
                ),
                child: const Text('日详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('日详情'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      final order = reverse
          ? ['下班', '上班', '下班', '上班']
          : ['上班', '下班', '上班', '下班'];
      for (final kind in order) {
        await tester.tap(find.text('$kind照片'));
        await tester.pump();
        final path = kind == '上班' ? 'in' : 'out';
        await tester.runAsync(() => loader.load('https://example.test/$path'));
        await tester.pumpAndSettle();
        expect(find.byType(AttendancePhotoDialog), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('重新加载'), findsNothing);
        if (saves == 0) {
          final beforeSave = requests.length;
          await tester.tap(find.text('保存图片'));
          await tester.pumpAndSettle();
          expect(find.text('已保存到相册'), findsOneWidget);
          expect(requests.length, beforeSave);
          expect(saves, 1);
        }
        await tester.tap(find.byTooltip('关闭照片'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      expect(requests, reverse ? ['/out', '/in'] : ['/in', '/out']);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('照片连接不返回时必须结束等待并显示超时，不能一直空白', (tester) async {
    final loader = AttendancePhotoLoader(
      createClient: () => MockClient((_) => Completer<http.Response>().future),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AttendancePhotoDialog(
          photoUrl: 'https://example.test/checkout-hanging.jpg',
          loader: loader,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('正在加载照片…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(find.textContaining('超时'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('正在加载照片…'), findsNothing);
  });
}
