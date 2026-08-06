import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';

void main() {
  const header = '日期,项目名称,BOSS工作类型,项目阶段,阶段活动,标题,工作内容';

  group('WorkLogCsvParser.parseRows', () {
    test('带引号字段内的逗号不会被拆开', () {
      final rows = WorkLogCsvParser.parseRows('a,"b,c",d');
      expect(rows.single, ['a', 'b,c', 'd']);
    });

    test('连续两个引号解析为一个字面量引号', () {
      final rows = WorkLogCsvParser.parseRows('a,"他说""你好""",c');
      expect(rows.single, ['a', '他说"你好"', 'c']);
    });

    test('引号字段内的换行不会断行', () {
      final rows = WorkLogCsvParser.parseRows('a,"第一行\n第二行",c');
      expect(rows.length, 1);
      expect(rows.single[1], '第一行\n第二行');
    });

    test('CRLF 与 LF 混用都能正确断行', () {
      final rows = WorkLogCsvParser.parseRows('a,b\r\nc,d\ne,f');
      expect(rows, [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ]);
    });

    test('末行没有换行符也能解析出来', () {
      final rows = WorkLogCsvParser.parseRows('a,b\nc,d');
      expect(rows.length, 2);
      expect(rows.last, ['c', 'd']);
    });

    test('空字段保留为空字符串而不是被丢弃', () {
      final rows = WorkLogCsvParser.parseRows('a,,c');
      expect(rows.single, ['a', '', 'c']);
    });
  });

  group('WorkLogCsvParser.parseList', () {
    test('解析真实样例行，工作内容中的逗号和序号完整保留', () {
      const content = '''$header
2026-08-04,面向比亚迪公司的项目-自筹,研发,软件编码阶段,软件编码,接口模块编码,"完成接口相关开发工作。1) 实现接口的核心业务逻辑，覆盖主要使用场景。2) 编写对应测试代码验证功能正确性。"''';

      final entries = WorkLogCsvParser.parseList(content);

      expect(entries.length, 1);
      final entry = entries.single;
      expect(entry.date, '2026-08-04');
      expect(entry.projectName, '面向比亚迪公司的项目-自筹');
      expect(entry.workType, '研发');
      expect(entry.stage, '软件编码阶段');
      expect(entry.activity, '软件编码');
      expect(entry.title, '接口模块编码');
      expect(entry.content, contains('2) 编写对应测试代码验证功能正确性。'));
    });

    test('UTF-8 BOM 不影响表头识别', () {
      const content = '﻿$header\n2026-08-04,项目,研发,阶段,活动,标题,内容';
      final entries = WorkLogCsvParser.parseList(content);
      expect(entries.single.projectName, '项目');
    });

    test('表头顺序打乱时按列名而非列序取值', () {
      const shuffled = '标题,日期,工作内容,项目名称,BOSS工作类型,项目阶段,阶段活动';
      const content = '$shuffled\n我的标题,2026-08-04,我的内容,我的项目,研发,阶段,活动';

      final entry = WorkLogCsvParser.parseList(content).single;

      expect(entry.title, '我的标题');
      expect(entry.date, '2026-08-04');
      expect(entry.content, '我的内容');
      expect(entry.projectName, '我的项目');
    });

    test('表头完全不匹配时回退为按列序读取', () {
      const content = 'c1,c2,c3,c4,c5,c6,c7\n2026-08-04,项目,研发,阶段,活动,标题,内容';
      final entry = WorkLogCsvParser.parseList(content).single;
      expect(entry.date, '2026-08-04');
      expect(entry.title, '标题');
    });

    test('末尾空行被忽略而不是产生空条目', () {
      const content = '$header\n2026-08-04,项目,研发,阶段,活动,标题,内容\n\n';
      expect(WorkLogCsvParser.parseList(content).length, 1);
    });

    test('日期非法的行被跳过', () {
      const content =
          '$header\n'
          '2026-13-01,项目,研发,阶段,活动,标题,内容\n'
          '2026-02-30,项目,研发,阶段,活动,标题,内容\n'
          'not-a-date,项目,研发,阶段,活动,标题,内容\n'
          '2026-08-04,项目,研发,阶段,活动,标题,内容';

      final entries = WorkLogCsvParser.parseList(content);

      expect(entries.length, 1);
      expect(entries.single.date, '2026-08-04');
    });

    test('单位数月日补零为标准格式', () {
      const content = '$header\n2026-8-4,项目,研发,阶段,活动,标题,内容';
      expect(WorkLogCsvParser.parseList(content).single.date, '2026-08-04');
    });

    test('空内容抛出可展示的中文异常', () {
      expect(
        () => WorkLogCsvParser.parseList(''),
        throwsA(isA<WorkLogCsvException>()),
      );
    });

    test('没有任何有效日期行时抛异常而不是静默返回空', () {
      const content = '$header\nnot-a-date,项目,研发,阶段,活动,标题,内容';
      expect(
        () => WorkLogCsvParser.parseList(content),
        throwsA(isA<WorkLogCsvException>()),
      );
    });
  });

  group('WorkLogCsvParser.parse', () {
    test('按日期归档，同一天以后出现的行覆盖先出现的', () {
      const content =
          '$header\n'
          '2026-08-04,项目,研发,阶段,活动,旧标题,旧内容\n'
          '2026-08-05,项目,研发,阶段,活动,另一天,内容\n'
          '2026-08-04,项目,研发,阶段,活动,新标题,新内容';

      final map = WorkLogCsvParser.parse(content);

      expect(map.length, 2);
      expect(map['2026-08-04']!.title, '新标题');
      expect(map['2026-08-05']!.title, '另一天');
    });
  });

  group('WorkLogEntry 序列化', () {
    test('toJson 与 fromJson 往返一致', () {
      const entry = WorkLogEntry(
        date: '2026-08-04',
        projectName: '项目',
        workType: '研发',
        stage: '阶段',
        activity: '活动',
        title: '标题',
        content: '内容,含逗号"含引号"',
      );

      final restored = WorkLogEntry.fromJson(entry.toJson());

      expect(restored.date, entry.date);
      expect(restored.content, entry.content);
      expect(restored.projectName, entry.projectName);
    });

    test('fromJson 缺字段时回退为空串而不是抛异常', () {
      final restored = WorkLogEntry.fromJson({'date': '2026-08-04'});
      expect(restored.date, '2026-08-04');
      expect(restored.title, '');
      expect(restored.content, '');
    });
  });
}
