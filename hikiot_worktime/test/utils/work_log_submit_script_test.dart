import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/utils/work_log_submit_script.dart';

void main() {
  const entry = WorkLogEntry(
    date: '2026-08-05',
    projectName: '面向比亚迪公司的项目-自筹',
    workType: '研发',
    stage: '软件编码阶段',
    activity: '软件编码',
    title: '接口模块编码',
    content: '完成接口相关开发工作。1) 实现核心逻辑，覆盖场景。',
  );

  Map<String, dynamic> build(WorkLogEntry e, {String actWork = '8.55'}) {
    return WorkLogSubmitScript.buildWorkLogData(
      entry: e,
      actWork: actWork,
      projectId: 'PROJECT_aaa',
      projectCode: 'PROJECT_bbb',
      auditor: ';USERINFO_ccc',
    );
  }

  group('LOGTYPE 映射', () {
    test('CSV 中出现的三种类型映射到实测编码', () {
      // 编码取自表单下拉 DataSource，并经真实提交验证
      expect(WorkLogSubmitScript.resolveLogType('研发'), '5');
      expect(WorkLogSubmitScript.resolveLogType('设计'), '10');
      expect(WorkLogSubmitScript.resolveLogType('测试'), '7');
    });

    test('其余类型也已录入，便于 CSV 扩展', () {
      expect(WorkLogSubmitScript.resolveLogType('会议'), '1');
      expect(WorkLogSubmitScript.resolveLogType('其他'), '20');
      expect(WorkLogSubmitScript.logTypeCodes.length, 18);
    });

    test('未知类型返回 null 而不是猜一个', () {
      expect(WorkLogSubmitScript.resolveLogType('不存在的类型'), isNull);
    });

    test('构造报文时遇到未知类型直接抛错，避免提交脏数据', () {
      expect(
        () => build(
          const WorkLogEntry(
            date: '2026-08-05',
            projectName: 'p',
            workType: '未知',
            stage: '',
            activity: '',
            title: 't',
            content: 'c',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('「无」到空串的归一化', () {
    test('CSV 的「无」提交为空串', () {
      // 实测切到设计类型后，PROJECTPHASE/PHASEACTIVITIES 提交的就是 ""
      expect(WorkLogSubmitScript.normalizeOptional('无'), '');
      expect(WorkLogSubmitScript.normalizeOptional(' 无 '), '');
      expect(WorkLogSubmitScript.normalizeOptional(''), '');
    });

    test('正常值原样保留', () {
      expect(WorkLogSubmitScript.normalizeOptional('软件编码阶段'), '软件编码阶段');
    });

    test('设计类型的阶段与活动在报文中为空串', () {
      final data = build(
        const WorkLogEntry(
          date: '2026-08-10',
          projectName: 'p',
          workType: '设计',
          stage: '无',
          activity: '无',
          title: 't',
          content: 'c',
        ),
      );

      expect(data['LOGTYPE'], '10');
      expect(data['PROJECTPHASE'], '');
      expect(data['PHASEACTIVITIES'], '');
    });
  });

  group('日期格式', () {
    test('LOGDATE 为 yyyyMMdd，SelectDate 为 yyyy-M-d', () {
      final data = build(entry);
      expect(data['LOGDATE'], '20260805');
      expect(data['SelectDate'], '2026-8-5');
    });

    test('两位数月日不补零到 SelectDate，但 LOGDATE 补零', () {
      final data = build(
        const WorkLogEntry(
          date: '2026-12-25',
          projectName: 'p',
          workType: '研发',
          stage: '',
          activity: '',
          title: 't',
          content: 'c',
        ),
      );
      expect(data['LOGDATE'], '20261225');
      expect(data['SelectDate'], '2026-12-25');
    });
  });

  group('报文字段', () {
    test('CSV 各列映射到对应字段', () {
      final data = build(entry, actWork: '8.55');

      expect(data['ObjectType'], 'WORKLOG');
      expect(data['ENAME'], '接口模块编码');
      expect(data['LOGCONTENT'], contains('覆盖场景'));
      expect(data['PROJECTPHASE'], '软件编码阶段');
      expect(data['PHASEACTIVITIES'], '软件编码');
      expect(data['PROJECTNAME'], '面向比亚迪公司的项目-自筹');
      expect(data['ACTWORK'], '8.55');
      expect(data['LOGTYPE'], '5');
    });

    test('固定常量由调用方注入而非硬编码', () {
      final data = build(entry);
      expect(data['PROJECTID'], 'PROJECT_aaa');
      expect(data['PROJECTCODE'], 'PROJECT_bbb');
      expect(data['AUDITOR'], ';USERINFO_ccc');
    });

    test('新建日志不带 ObjectID/EID，避免误改已有记录', () {
      final data = build(entry);
      expect(data.containsKey('ObjectID'), isFalse);
      expect(data.containsKey('EID'), isFalse);
    });
  });

  group('提交脚本', () {
    test('业务数据被编码为 JSON 字符串嵌入，不破坏脚本', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        captureStoreName: '__store',
      );

      final match = RegExp(
        r'var WORKLOG_DATA = (".*?");\n',
        dotAll: true,
      ).firstMatch(script);
      expect(match, isNotNull);

      final decoded = jsonDecode(jsonDecode(match!.group(1)!) as String);
      expect(decoded['ENAME'], '接口模块编码');
      expect(decoded['ACTWORK'], '8.55');
    });

    test('复用抓包中的会话上下文，不内嵌任何凭据', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        captureStoreName: '__store',
      );

      expect(script.contains('findPara'), isTrue);
      expect(script.contains('__store'), isTrue);
      // 绝不能把凭据字段写进脚本
      expect(script.contains('Password'), isFalse);
    });

    test('会话查找只依赖 UserID，不得要求 ServiceUri', () {
      // 登录后首页自动发的 CheckUserUnReadMessage / GetIntervals 不带
      // ServiceUri，但 para 完整。若把 ServiceUri 加回筛选条件，
      // 刚登录时就取不到会话，一键提交会失效。
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        captureStoreName: '__store',
      );

      final findParaBody = RegExp(
        r'function findPara\(\) \{(.*?)\n        \}',
        dotAll: true,
      ).firstMatch(script)?.group(1);

      expect(findParaBody, isNotNull);
      expect(findParaBody!.contains('UserID'), isTrue);
      expect(findParaBody.contains('ServiceUri'), isFalse);
    });

    test('会话探测脚本同样不要求 ServiceUri', () {
      final probe = WorkLogSubmitScript.buildSessionProbeScript(
        captureStoreName: '__store',
      );

      expect(probe.contains('UserID'), isTrue);
      expect(probe.contains('ServiceUri'), isFalse);
      expect(probe.contains('Password'), isFalse);
    });

    test('提取常量脚本只取业务标识，不取凭据', () {
      final script = WorkLogSubmitScript.buildExtractConstantsScript(
        captureStoreName: '__store',
      );

      expect(script.contains('PROJECTID'), isTrue);
      expect(script.contains('AUDITOR'), isTrue);
      expect(script.contains('Password'), isFalse);
      expect(script.contains('LoginID'), isFalse);
    });
  });
}
