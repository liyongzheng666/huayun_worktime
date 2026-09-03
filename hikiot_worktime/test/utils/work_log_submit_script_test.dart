import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/utils/work_log_request_capture.dart';
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

  /// [projectName] 默认给 BOSS 那边的写法（比 CSV 多一个「(2)」），
  /// 好让「报文用的是哪一个」在断言里一眼可辨。
  Map<String, dynamic> build(
    WorkLogEntry e, {
    String actWork = '8.55',
    String projectName = '面向比亚迪公司的项目-自筹(2)',
  }) {
    return WorkLogSubmitScript.buildWorkLogData(
      entry: e,
      actWork: actWork,
      projectId: 'PROJECT_aaa',
      projectCode: 'PROJECT_bbb',
      projectName: projectName,
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

  group('项目与审核人不许为空', () {
    // 两者现在来自各自独立的来源（项目清单 / 个人设置），
    // 「其中一个没取到」是真会发生的状态。空着提交不报错，
    // 只会把日志记到错的地方或发给错的审批人，事后翻 BOSS 才发现。
    test('没有项目 ID 时拒绝构造报文', () {
      expect(
        () => WorkLogSubmitScript.buildWorkLogData(
          entry: entry,
          actWork: '8.00',
          projectId: '',
          projectCode: 'PROJECT_bbb',
          projectName: '某项目',
          auditor: ';USERINFO_ccc',
        ),
        throwsArgumentError,
      );
    });

    test('没有审核人时拒绝构造报文', () {
      expect(
        () => WorkLogSubmitScript.buildWorkLogData(
          entry: entry,
          actWork: '8.00',
          projectId: 'PROJECT_aaa',
          projectCode: 'PROJECT_bbb',
          projectName: '某项目',
          auditor: '',
        ),
        throwsArgumentError,
      );
    });

    test('项目编码可以为空，由服务端兜底', () {
      // 改选项目后扫不到 EUID 时就是这样；留空好过带一个确定错误的旧编码
      expect(
        WorkLogSubmitScript.buildWorkLogData(
          entry: entry,
          actWork: '8.00',
          projectId: 'PROJECT_aaa',
          projectCode: '',
          projectName: '某项目',
          auditor: ';USERINFO_ccc',
        )['PROJECTID'],
        'PROJECT_aaa',
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
      // PROJECTNAME 不在这里断言：它来自 BOSS 而非 CSV，见下方「PROJECTNAME 取值」
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
        dateStr: entry.date,
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
        dateStr: entry.date,
        captureStoreName: '__store',
      );

      // 会话查找与请求发送都走公共片段，具体约束在
      // boss_session_script_test.dart 中统一断言，这里只验证确实接上了。
      expect(script.contains('bossFindPara()'), isTrue);
      expect(script.contains('bossCall('), isTrue);
      expect(script.contains('__store'), isTrue);
      // 绝不能把凭据字段写进脚本
      expect(script.contains('Password'), isFalse);
    });

    test('提交成功时取出新建记录的 WORKLOG ID', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        dateStr: entry.date,
        captureStoreName: '__store',
      );

      // 只有拿到 WORKLOG_ 开头的 ID 才算成功，
      // 否则可能是服务端返回了错误页而 HTTP 仍是 200。
      expect(script.contains("indexOf('WORKLOG_') === 0"), isTrue);
      expect(script.contains("res.reason || 'unexpected'"), isTrue);
      expect(script.contains('failed: true'), isTrue);
    });

    test('保存前先查当天已填工时，只有明确为零才写入', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        dateStr: entry.date,
        captureStoreName: '__store',
      );

      final preflight = script.indexOf('var before = queryUsedHours()');
      final save = script.indexOf('bossCall(para, SAVE_SERVICE_URI');
      expect(preflight, greaterThanOrEqualTo(0));
      expect(save, greaterThan(preflight));
      expect(script.contains('before.used > 0'), isTrue);
      expect(script.contains('alreadySubmitted: true'), isTrue);
    });

    test('前置查询失败时暂缓，不把未知状态当成未提交', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        dateStr: entry.date,
        captureStoreName: '__store',
      );

      expect(script.contains('deferred: true'), isTrue);
      expect(script.contains("reason: 'preflightUnavailable'"), isTrue);
      expect(script.contains('未能确认当天是否已提交，本次已暂缓'), isTrue);
    });

    test('保存响应异常后复查当天记录，避免网络抖动导致用户重复提交', () {
      final script = WorkLogSubmitScript.build(
        workLogData: build(entry),
        dateStr: entry.date,
        captureStoreName: '__store',
      );

      final save = script.indexOf('bossCall(para, SAVE_SERVICE_URI');
      final postCheck = script.indexOf('var after = queryUsedHours()');
      expect(postCheck, greaterThan(save));
      expect(script.contains('submitResultUnknown'), isTrue);
      expect(script.contains('请勿立即重试'), isTrue);
    });

    test('会话探测报告已抓到的请求数，便于区分「没登录」和「没抓到」', () {
      final probe = WorkLogSubmitScript.buildSessionProbeScript(
        captureStoreName: '__store',
      );

      expect(probe.contains('bossFindPara()'), isTrue);
      expect(probe.contains('captured'), isTrue);
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

  group('抓包容量', () {
    test('单条记录上限远大于 BOSS 的 grid 响应', () {
      // 实测一条 grid 响应就有 6005 字符被截断，需要的列正好在切口之外。
      // 截断与「形状不认识」在结果上完全一样，曾因此误判过一轮。
      expect(WorkLogRequestCapture.maxRecordChars, greaterThanOrEqualTo(20000));
    });

    test('条数上限仍足以容纳首页自身的请求', () {
      // BOSS 经典首页加载自身就会发约 40 个请求，缓冲太小会把
      // 后续真正需要的业务响应挤出去
      expect(WorkLogRequestCapture.maxRecords, greaterThanOrEqualTo(60));
    });
  });

  group('PROJECTNAME 取值', () {
    test('报文用 BOSS 的项目名，不用 CSV 的写法', () {
      // 决定归属的是 PROJECTID，名字必须跟它同源；
      // 两者取自不同来源时，报文里这两个字段会指向不同的项目
      final data = build(entry);

      expect(data['PROJECTNAME'], '面向比亚迪公司的项目-自筹(2)');
      expect(data['PROJECTNAME'], isNot(entry.projectName));
      expect(data['PROJECTID'], 'PROJECT_aaa');
    });

    test('传入什么就填什么，不擅自改写', () {
      final data = build(entry, projectName: '另一个项目');
      expect(data['PROJECTNAME'], '另一个项目');
    });
  });
}
