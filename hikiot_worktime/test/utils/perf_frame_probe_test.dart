import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/perf_frame_probe.dart';

void main() {
  test('默认诊断开关关闭，begin/end不要求绑定或文件插件', () async {
    expect(PerfFrameProbe.enabled, isFalse);
    expect(PerfFrameProbe.begin('report_confirm'), isNull);
    expect(PerfFrameProbe.begin('private/http://secret'), isNull);
    await PerfFrameProbe.end(123);
    await PerfFrameProbe.end(null);
  });

  test('关闭时measure直接执行原操作并保留返回值', () async {
    var called = 0;
    expect(
      await PerfFrameProbe.measure('monthly.load', () async => ++called),
      1,
    );
    expect(called, 1);
  });

  test('关闭时measure保持同步异常对象', () {
    final error = StateError('expected test failure');
    expect(
      () => PerfFrameProbe.measure<int>('monthly.load', () => throw error),
      throwsA(same(error)),
    );
  });

  test('关闭时measure保持异步异常对象', () async {
    final error = StateError('expected test failure');
    await expectLater(
      PerfFrameProbe.measure<int>(
        'monthly.load',
        () => Future<int>.error(error),
      ),
      throwsA(same(error)),
    );
  });

  test('帧耗时按整数统计，阈值严格大于，不输出FPS', () {
    final samples = PerfFrameAccumulator();
    for (final value in [1000, 8333, 10000, 16667, 20000]) {
      samples.recordFrame(
        buildUs: value,
        rasterUs: value + 1,
        totalSpanUs: value + 2,
      );
    }
    final json = samples.toJson();
    final ui = json['ui']! as Map<String, Object>;
    expect(json['sampleCount'], 5);
    expect(ui['p50Us'], 10000);
    expect(ui['p95Us'], 20000);
    expect(ui['meanUs'], 11200);
    expect(ui['over8333Us'], 3);
    expect(ui['over16667Us'], 1);
    expect(json['fps'], isNull);
  });

  test('样本上限与无效帧不会突破有界内存', () {
    final samples = PerfFrameAccumulator(maxSamples: 2);
    samples.recordFrame(buildUs: -1, rasterUs: 1, totalSpanUs: 1);
    for (var i = 0; i < 5; i++) {
      samples.recordFrame(buildUs: i, rasterUs: i, totalSpanUs: i);
    }
    final json = samples.toJson();
    expect(samples.count, 2);
    expect(json['invalidFrames'], 1);
    expect(json['droppedFrames'], 3);
    expect(() => PerfFrameAccumulator(maxSamples: 3601), throwsRangeError);
  });

  test('无帧是未知，不伪装成零耗时', () {
    final json = PerfFrameAccumulator().toJson();
    expect(json['ui'], {'count': 0, 'status': 'no_reported_samples'});
  });

  test('Release延迟批次排除开始前帧及25秒窗口之后的帧', () {
    final samples = PerfFrameAccumulator();
    FrameTiming frame(int start) => FrameTiming(
      vsyncStart: start - 1,
      buildStart: start,
      buildFinish: start + 2,
      rasterStart: start + 3,
      rasterFinish: start + 5,
      rasterFinishWallTime: start + 5,
    );
    for (final start in [999, 1000, 1001, 2000, 2001]) {
      samples.recordTiming(
        frame(start),
        afterBuildStartUs: 1000,
        untilBuildStartUs: 2000,
      );
    }
    final data = samples.toJson();
    expect(data['sampleCount'], 2);
    expect(data['excludedBeforeWindow'], 2);
    expect(data['excludedAfterWindow'], 1);
  });

  test('只记录固定操作名和时长，不收集业务内容或异常正文', () {
    final samples = PerfFrameAccumulator();
    expect(
      samples.recordOperation(
        name: 'boss.month.query',
        durationUs: 5000,
        failed: true,
        completedAfterCapture: true,
      ),
      isTrue,
    );
    expect(
      samples.recordOperation(
        name: 'http://user-secret',
        durationUs: 1,
        failed: false,
      ),
      isFalse,
    );
    final operations = samples.toJson()['operationDuration']! as List;
    expect(operations, [
      {
        'name': 'boss.month.query',
        'durationUs': 5000,
        'failed': true,
        'completedAfterCapture': true,
      },
    ]);
  });

  test('操作列表有界，统计快照不会被后续追加修改', () {
    final samples = PerfFrameAccumulator();
    samples.recordOperation(name: 'monthly.load', durationUs: 1, failed: false);
    final previous = samples.toJson();
    for (var i = 0; i < 140; i++) {
      samples.recordOperation(
        name: 'monthly.load',
        durationUs: i,
        failed: false,
      );
    }
    expect((previous['operationDuration']! as List).length, 1);
    final next = samples.toJson();
    expect((next['operationDuration']! as List).length, 128);
    expect(next['droppedOperations'], 13);
  });
}
