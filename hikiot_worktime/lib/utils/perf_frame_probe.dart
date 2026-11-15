import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

final _labelPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,63}$');
const _captureLimitUs = 25 * 1000 * 1000;

/// 有界的纯整数性能统计，不接收账号、正文或网络请求内容。
class PerfFrameAccumulator {
  PerfFrameAccumulator({this.maxSamples = 3600}) {
    if (maxSamples <= 0 || maxSamples > 3600) {
      throw RangeError.range(maxSamples, 1, 3600, 'maxSamples');
    }
  }

  final int maxSamples;
  final _build = <int>[];
  final _raster = <int>[];
  final _total = <int>[];
  final _operations = <Map<String, Object>>[];
  int invalidFrames = 0;
  int droppedFrames = 0;
  int droppedOperations = 0;
  int excludedBeforeWindow = 0;
  int excludedAfterWindow = 0;

  int get count => _build.length;

  void recordTiming(
    FrameTiming timing, {
    required int afterBuildStartUs,
    required int untilBuildStartUs,
  }) {
    final start = timing.timestampInMicroseconds(FramePhase.buildStart);
    if (start <= afterBuildStartUs) {
      excludedBeforeWindow++;
      return;
    }
    if (start > untilBuildStartUs) {
      excludedAfterWindow++;
      return;
    }
    recordFrame(
      buildUs: timing.buildDuration.inMicroseconds,
      rasterUs: timing.rasterDuration.inMicroseconds,
      totalSpanUs: timing.totalSpan.inMicroseconds,
    );
  }

  void recordFrame({
    required int buildUs,
    required int rasterUs,
    required int totalSpanUs,
  }) {
    if (buildUs < 0 || rasterUs < 0 || totalSpanUs < 0) {
      invalidFrames++;
      return;
    }
    if (count >= maxSamples) {
      droppedFrames++;
      return;
    }
    _build.add(buildUs);
    _raster.add(rasterUs);
    _total.add(totalSpanUs);
  }

  bool recordOperation({
    required String name,
    required int durationUs,
    required bool failed,
    bool completedAfterCapture = false,
  }) {
    if (!_labelPattern.hasMatch(name) || durationUs < 0) return false;
    if (_operations.length >= 128) {
      droppedOperations++;
      return false;
    }
    _operations.add({
      'name': name,
      'durationUs': durationUs,
      'failed': failed,
      'completedAfterCapture': completedAfterCapture,
    });
    return true;
  }

  Map<String, Object?> toJson() => {
    'sampleCount': count,
    'sampleLimit': maxSamples,
    'ui': _stats(_build),
    'raster': _stats(_raster),
    'totalSpan': _stats(_total),
    'invalidFrames': invalidFrames,
    'droppedFrames': droppedFrames,
    'droppedOperations': droppedOperations,
    'excludedBeforeWindow': excludedBeforeWindow,
    'excludedAfterWindow': excludedAfterWindow,
    'operationDuration': [for (final item in _operations) Map.of(item)],
    'fps': null,
  };

  static Map<String, Object> _stats(List<int> values) {
    if (values.isEmpty) return {'count': 0, 'status': 'no_reported_samples'};
    final sorted = List<int>.of(values)..sort();
    int percentile(int percent) =>
        sorted[(sorted.length * percent + 99) ~/ 100 - 1];
    return {
      'count': sorted.length,
      'unit': 'microseconds',
      'minUs': sorted.first,
      'meanUs':
          sorted.fold<int>(0, (sum, value) => sum + value) ~/ sorted.length,
      'p50Us': percentile(50),
      'p95Us': percentile(95),
      'maxUs': sorted.last,
      'over8333Us': sorted.where((value) => value > 8333).length,
      'over16667Us': sorted.where((value) => value > 16667).length,
    };
  }
}

class _Capture {
  _Capture(this.ticket, this.scope, this.binding, this.frameFenceUs)
    : fileName =
          'perf_${scope}_${DateTime.now().microsecondsSinceEpoch}_$ticket.json';

  final int ticket;
  final String scope;
  final SchedulerBinding binding;
  final int frameFenceUs;
  final String fileName;
  final samples = PerfFrameAccumulator();
  final clock = Stopwatch()..start();
  Future<void> writes = Future<void>.value();
  Timer? timer;
  bool finished = false;
  bool listening = false;
  int operationsInFlight = 0;

  Map<String, Object?> toJson() => {
    'schema': 'huayun.frame-probe.v1',
    'scope': scope,
    'captureDurationUs': clock.elapsedMicroseconds,
    'requestedFrameWindowUs': _captureLimitUs,
    'finished': finished,
    'operationsInFlight': operationsInFlight,
    'timingDelivery': 'engine_batched_reported_frames',
    'tailBatchMayBeMissing': true,
    'thresholdCountsAreNotFps': true,
    ...samples.toJson(),
  };
}

/// 仅诊断包启用。Release的FrameTiming约每秒成批上报，末尾批次可能尚未送达。
///
/// 默认false时不注册回调、不创建Timer、不读写文件；measure直接调用原操作。
class PerfFrameProbe {
  PerfFrameProbe._();

  static const bool enabled = bool.fromEnvironment('HUAYUN_PERF_PROBE');
  static _Capture? _active;
  static int _nextTicket = 0;

  static int? begin(String scope) {
    if (!enabled || !_labelPattern.hasMatch(scope)) return null;
    _Capture? capture;
    try {
      final binding = SchedulerBinding.instance;
      final previous = _active;
      if (previous != null) unawaited(_finish(previous));
      capture = _Capture(
        ++_nextTicket,
        scope,
        binding,
        binding.currentSystemFrameTimeStamp.inMicroseconds,
      );
      _active = capture;
      capture.listening = true;
      binding.addTimingsCallback(_onTimings);
      final current = capture;
      capture.timer = Timer(const Duration(seconds: 25), () {
        unawaited(_finish(current));
      });
      return capture.ticket;
    } catch (_) {
      if (capture != null) {
        capture.timer?.cancel();
        capture.clock.stop();
        if (capture.listening) {
          try {
            capture.binding.removeTimingsCallback(_onTimings);
          } catch (_) {}
          capture.listening = false;
        }
        if (identical(_active, capture)) _active = null;
      }
      return null;
    }
  }

  static Future<void> end(int? ticket) {
    if (!enabled || ticket == null) return Future<void>.value();
    final capture = _active;
    return capture != null && capture.ticket == ticket
        ? _finish(capture)
        : Future<void>.value();
  }

  static Future<T> measure<T>(String operation, Future<T> Function() body) {
    final capture = _active;
    if (!enabled ||
        capture == null ||
        capture.finished ||
        !_labelPattern.hasMatch(operation)) {
      return body();
    }
    return _measure(capture, operation, body);
  }

  static Future<T> _measure<T>(
    _Capture capture,
    String operation,
    Future<T> Function() body,
  ) async {
    final clock = Stopwatch()..start();
    capture.operationsInFlight++;
    var failed = true;
    try {
      final result = await body();
      failed = false;
      return result;
    } finally {
      clock.stop();
      capture.operationsInFlight--;
      final recorded = capture.samples.recordOperation(
        name: operation,
        durationUs: clock.elapsedMicroseconds,
        failed: failed,
        completedAfterCapture: capture.finished,
      );
      if (capture.finished && recorded) unawaited(_persist(capture));
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    final capture = _active;
    if (capture == null || capture.finished) return;
    for (final timing in timings) {
      // 批量延迟或应用挂起时Timer可能晚执行，帧窗口仍限制在25秒内。
      // 使用引擎epoch，不与DateTime的epoch比较。
      capture.samples.recordTiming(
        timing,
        afterBuildStartUs: capture.frameFenceUs,
        untilBuildStartUs: capture.frameFenceUs + _captureLimitUs,
      );
    }
  }

  static Future<void> _finish(_Capture capture) {
    if (capture.finished) return Future<void>.value();
    capture.finished = true;
    capture.timer?.cancel();
    capture.clock.stop();
    if (capture.listening) {
      capture.binding.removeTimingsCallback(_onTimings);
      capture.listening = false;
    }
    if (identical(_active, capture)) _active = null;
    return _persist(capture);
  }

  static Future<void> _persist(_Capture capture) {
    final content = jsonEncode(capture.toJson());
    final write = capture.writes.then((_) async {
      File? temporary;
      try {
        final documents = await getApplicationDocumentsDirectory();
        final folder = Directory('${documents.path}/huayun_perf');
        await folder.create(recursive: true);
        final target = File('${folder.path}/${capture.fileName}');
        temporary = File('${target.path}.tmp');
        await temporary.writeAsString(content, flush: true);
        await temporary.rename(target.path);
      } catch (_) {
        // 诊断记录失败不影响业务，也不输出异常中的路径或其他资料。
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {}
      }
    });
    capture.writes = write;
    return write;
  }
}
