import 'dart:convert';
import 'dart:io';

/// 执行真实生成脚本；调用方用 console.log 输出一份 JSON 作为断言对象。
dynamic runJavaScript(String source) {
  final result = Process.runSync('node', ['-e', source]);
  if (result.exitCode != 0) {
    throw StateError('JavaScript 回归执行失败：${result.stderr}');
  }
  return jsonDecode((result.stdout as String).trim());
}
