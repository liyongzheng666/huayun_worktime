import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_fill_script.dart';

void main() {
  /// 从生成的脚本里取回 `var TARGETS = [...]` 的实际内容，
  /// 用于验证值在拼进 JS 后仍然完整且合法。
  List<dynamic> extractTargets(String script) {
    final match = RegExp(
      r'var TARGETS = (\[.*?\]);',
      dotAll: true,
    ).firstMatch(script);
    expect(match, isNotNull, reason: '脚本中应包含 TARGETS 声明');
    return jsonDecode(match!.group(1)!) as List<dynamic>;
  }

  group('WorkLogFillScript.build', () {
    test('字段的标签与值被完整编码进脚本', () {
      final script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '标题', value: '接口模块编码'),
        WorkLogFillField(label: '正常工时', value: '8.55'),
      ]);

      final targets = extractTargets(script);

      expect(targets.length, 2);
      expect(targets[0]['label'], '标题');
      expect(targets[0]['value'], '接口模块编码');
      expect(targets[1]['label'], '正常工时');
      expect(targets[1]['value'], '8.55');
    });

    test('值中的双引号被转义，不会截断脚本', () {
      final script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '工作内容', value: '他说"完成了"，然后提交'),
      ]);

      final targets = extractTargets(script);
      expect(targets.single['value'], '他说"完成了"，然后提交');
    });

    test('值中的换行被转义为 \\n 而不是真实断行', () {
      final script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '工作内容', value: '第一行\n第二行'),
      ]);

      // 原始换行若未转义，会把 JS 字符串字面量拆断
      expect(script.contains('第一行\n第二行'), isFalse);
      expect(extractTargets(script).single['value'], '第一行\n第二行');
    });

    test('值中的反斜杠与单引号不破坏脚本', () {
      const tricky = r"路径 C:\temp 与 it's fine";
      final script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '工作内容', value: tricky),
      ]);

      expect(extractTargets(script).single['value'], tricky);
    });

    test('真实的多序号工作内容往返无损', () {
      const content =
          '完成接口相关开发工作。1) 实现接口的核心业务逻辑，覆盖主要使用场景。'
          '2) 编写对应测试代码验证功能正确性。3) 修复测试中发现的缺陷和性能问题。';

      final script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '工作内容', value: content),
      ]);

      expect(extractTargets(script).single['value'], content);
    });

    test('空字段列表也生成合法脚本', () {
      final script = WorkLogFillScript.build(const []);
      expect(extractTargets(script), isEmpty);
    });
  });

  group('脚本行为约定', () {
    late String script;

    setUp(() {
      script = WorkLogFillScript.build(const [
        WorkLogFillField(label: '标题', value: 'x'),
      ]);
    });

    test('不包含任何点击保存的动作', () {
      // 自动提交到公司真实系统风险过高，必须由用户核对后手动保存。
      expect(script.contains('.click()'), isFalse);
      expect(script.contains('保存'), isFalse);
    });

    test('跳过只读控件（自研伪下拉直接赋值会提交空值）', () {
      expect(script.contains('readOnly'), isTrue);
      expect(script.contains('readonly'), isTrue);
      expect(script.contains('skipped'), isTrue);
    });

    test('按标签定位而非按 id（BOSS 的 guid 前缀 id 每次加载都变）', () {
      expect(script.contains('nearbyLabel'), isTrue);
      expect(script.contains('guid'), isFalse);
    });

    test('赋值后补发 input/change/blur 事件让框架感知', () {
      expect(script.contains("'input'"), isTrue);
      expect(script.contains("'change'"), isTrue);
      expect(script.contains("'blur'"), isTrue);
      expect(script.contains('jQuery'), isTrue);
    });

    test('返回 filled/missing/skipped 三类结果供上层提示', () {
      expect(script.contains('filled'), isTrue);
      expect(script.contains('missing'), isTrue);
      expect(script.contains('skipped'), isTrue);
    });
  });
}
