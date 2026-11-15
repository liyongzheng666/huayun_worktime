import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/screens/work_report_webview_screen.dart';
import 'package:hikiot_worktime/services/storage_service.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller implements InAppWebViewController {
  double hours = 6.5;
  Completer<void>? queryGate;
  Completer<void>? captureGate;
  final sources = <String>[];
  final savedEvents = <Map<String, String>>[];

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    sources.add(source);
    if (source.contains('__workLogObservedSave')) {
      await captureGate?.future;
      final events = List.of(savedEvents);
      savedEvents.clear();
      return jsonEncode(events);
    }
    if (source.contains('WorkReportService.GetWorkHours')) {
      await queryGate?.future;
      return jsonEncode({'ok': true, 'used': hours});
    }
    return '{"ok":false}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform extends InAppWebViewPlatform {
  _Platform(this.controller);
  final _Controller controller;
  late _WebView view;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => view = _WebView(params, controller);
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params, this.controller) : super.implementation();
  final _Controller controller;
  bool created = false;

  @override
  Widget build(BuildContext context) {
    if (!created) {
      created = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => params.onWebViewCreated?.call(controller),
      );
    }
    return const SizedBox.expand();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

void main() {
  late _Controller controller;
  late _Platform platform;
  final storage = StorageService();
  const date = '2026-09-10';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = _Controller();
    platform = _Platform(controller);
    InAppWebViewPlatform.instance = platform;
    const entry = WorkLogEntry(
      date: date,
      projectName: '测试项目',
      workType: '研发',
      stage: '无',
      activity: '无',
      title: '测试标题',
      content: '测试内容',
    );
    await storage.saveWorkLogEntries({date: entry.toJson()});
  });

  Future<void> pump(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkReportWebViewScreen(fillDate: DateTime.parse(date)),
      ),
    );
    await pump(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  }

  testWidgets('前置查询发现已提交时更新真实日期缓存，不再次发保存请求', (tester) async {
    await open(tester);
    await tester.tap(find.text('提交日志'));
    await pump(tester);
    expect((await storage.loadBossHours('2026-09'))[date], 6.5);
    expect(await storage.hasBossHoursForDate(date), isTrue);
    expect(
      controller.sources.where(
        (source) => source.contains('bossCall(para, SAVE_SERVICE_URI'),
      ),
      isEmpty,
    );
    await close(tester);
  });

  testWidgets('网页保存其它日期后回读合计，重复轮询不重复查询', (tester) async {
    await open(tester);
    controller.savedEvents.add({
      'date': '2026-09-09',
      'objectId': 'WORKLOG_web',
    });
    platform.view.params.onLoadStop?.call(
      controller,
      WebUri('https://example.test'),
    );
    await pump(tester);
    expect((await storage.loadBossHours('2026-09'))['2026-09-09'], 6.5);
    expect((await storage.loadBossHours('2026-09'))[date], isNull);
    final queries = controller.sources
        .where((source) => source.contains('WorkReportService.GetWorkHours'))
        .length;
    await tester.pump(const Duration(seconds: 2));
    await pump(tester);
    expect(
      controller.sources
          .where((source) => source.contains('WorkReportService.GetWorkHours'))
          .length,
      queries,
    );
    await close(tester);
  });

  testWidgets('迟到的前置查询不覆盖等待期间新提交的工时', (tester) async {
    controller.queryGate = Completer<void>();
    await open(tester);
    await tester.tap(find.text('提交日志'));
    await pump(tester);
    await storage.saveBossHoursForDate(date, 9.25);
    controller.queryGate!.complete();
    await pump(tester);
    expect((await storage.loadBossHours('2026-09'))[date], 9.25);
    await close(tester);
  });

  testWidgets('网页停留超过两分钟仍识别保存，多次加载事件只启动一个轮询', (tester) async {
    await open(tester);
    platform.view.params.onLoadStop?.call(
      controller,
      WebUri('https://example.test'),
    );
    platform.view.params.onLoadStop?.call(
      controller,
      WebUri('https://example.test/next'),
    );
    await pump(tester);
    expect(
      controller.sources.where(
        (source) => source.contains('__workLogObservedSave'),
      ),
      hasLength(1),
    );
    for (var i = 0; i < 62; i++) {
      await tester.pump(const Duration(seconds: 2));
      await pump(tester);
    }
    controller.savedEvents.add({
      'date': '2026-09-09',
      'objectId': 'WORKLOG_late',
    });
    await tester.pump(const Duration(seconds: 2));
    await pump(tester);
    expect((await storage.loadBossHours('2026-09'))['2026-09-09'], 6.5);
    await close(tester);
  });

  testWidgets('保存事件识别尚未返回时离开网页，不再启动工时回查', (tester) async {
    controller.captureGate = Completer<void>();
    await open(tester);
    controller.savedEvents.add({
      'date': '2026-09-09',
      'objectId': 'WORKLOG_web',
    });
    platform.view.params.onLoadStop?.call(
      controller,
      WebUri('https://example.test'),
    );
    await pump(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.captureGate!.complete();
    await tester.pump(const Duration(seconds: 3));
    await pump(tester);
    expect(
      controller.sources.where(
        (source) => source.contains('WorkReportService.GetWorkHours'),
      ),
      isEmpty,
    );
    expect(await storage.loadBossHours('2026-09'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
