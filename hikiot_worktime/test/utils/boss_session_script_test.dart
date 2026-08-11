import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/boss_session_script.dart';
import 'package:hikiot_worktime/utils/work_log_boss_hours.dart';
import 'package:hikiot_worktime/utils/work_log_constants_scanner.dart';
import 'package:hikiot_worktime/utils/work_log_csv_parser.dart';
import 'package:hikiot_worktime/utils/work_log_diagnostics_script.dart';
import 'package:hikiot_worktime/utils/work_log_submit_script.dart';

/// 这些约束原先散在五个脚本里各断言一遍，结果是同一个 BUG 要修五次，
/// 实际上两次都漏修过。收口到 BossSessionScript 之后，在这里断言一次即可。
void main() {
  const store = '__store';

  String sessionBody() =>
      BossSessionScript.sessionPreamble(captureStoreName: store);

  /// 所有需要读抓包的业务脚本，用来验证它们都走统一入口。
  Map<String, String> allScripts() {
    const entry = WorkLogEntry(
      date: '2026-08-05',
      projectName: '某项目',
      workType: '研发',
      stage: '软件编码阶段',
      activity: '软件编码',
      title: '标题',
      content: '内容',
    );

    return {
      '提交': WorkLogSubmitScript.build(
        workLogData: WorkLogSubmitScript.buildWorkLogData(
          entry: entry,
          actWork: '8.55',
          projectId: 'PROJECT_aaa',
          projectCode: 'PROJECT_bbb',
          projectName: '项目',
          auditor: ';USERINFO_ccc',
        ),
        captureStoreName: store,
      ),
      '会话探测': WorkLogSubmitScript.buildSessionProbeScript(
        captureStoreName: store,
      ),
      '提取常量': WorkLogSubmitScript.buildExtractConstantsScript(
        captureStoreName: store,
      ),
      '单日工时': WorkLogBossHours.buildFetchSingleDayScript(
        dateStr: '2026-08-05',
        captureStoreName: store,
      ),
      '整月工时': WorkLogBossHours.buildFetchMonthScript(
        year: 2026,
        month: 8,
        captureStoreName: store,
      ),
      '扫描常量': WorkLogConstantsScanner.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      ),
    };
  }

  group('bossCaptured 必须汇总所有同源 frame', () {
    test('递归遍历 window.frames，而不是只读主框架', () {
      // BOSS 是门户型系统，业务模块跑在 iframe 里，抓包钩子以
      // forMainFrameOnly:false 注入后在每个 frame 各存一份。
      // 只读主框架拿到的永远只有首页自身的请求，扫多久都不会有项目信息——
      // 这正是早期「自动获取项目信息」屡试屡败的真正原因（踩坑记录 2.7）。
      final body = sessionBody();
      expect(body.contains('win.frames'), isTrue);
      expect(body.contains('walk(window)'), isTrue);
    });

    test('跨域 frame 读不到时跳过而不是整体失败', () {
      expect(sessionBody().contains('catch'), isTrue);
    });

    test('合并多个 frame 后按抓取时间排序', () {
      // 各 frame 的记录在时间上交错，不排序的话「从后往前取最新」会取错，
      // 可能复用到一条更旧的会话。
      expect(sessionBody().contains('out.sort('), isTrue);
    });
  });

  group('会话查找的筛选条件', () {
    test('只依赖 UserID，不得要求 ServiceUri', () {
      // ServiceUri 是我们自己要设进去的值，拿它当筛选条件是逻辑错误。
      // 登录后首页自动发的 CheckUserUnReadMessage / GetIntervals 不带
      // ServiceUri，但 para 完整——要求它会让刚登录时取不到会话。
      final findPara = RegExp(
        r'function bossFindPara\(\) \{(.*?)\n      \}',
        dotAll: true,
      ).firstMatch(sessionBody())?.group(1);

      expect(findPara, isNotNull, reason: '应存在 bossFindPara 函数');
      expect(findPara!.contains('UserID'), isTrue);
      expect(findPara.contains('ServiceUri'), isFalse);
    });
  });

  group('凭据不得进入脚本', () {
    test('公共片段不含任何凭据字段', () {
      // BOSS 把 Password 明文放在每个业务请求体里（踩坑记录 3.12），
      // 脚本里一旦出现这些字面量，就意味着有人在往外搬凭据。
      final combined = sessionBody() + BossSessionScript.callPreamble();
      expect(combined.contains('Password'), isFalse);
      expect(combined.contains('LoginID'), isFalse);
    });

    test('所有业务脚本都不含凭据字段', () {
      allScripts().forEach((name, script) {
        expect(script.contains('Password'), isFalse, reason: '$name 脚本');
        expect(script.contains('LoginID'), isFalse, reason: '$name 脚本');
      });
    });
  });

  group('所有取数脚本都走统一入口', () {
    test('一律通过 bossCaptured() 读抓包，不直接摸 window 上的存储', () {
      // 直接读 window.<store> 就等于只看主框架。去掉公共片段后
      // 脚本正文里不应再出现存储名，否则说明又抄了一份只读主框架的实现。
      final preamble = sessionBody();
      allScripts().forEach((name, script) {
        final bodyOnly = script.replaceAll(preamble, '');
        expect(
          bodyOnly.contains(store),
          isFalse,
          reason: '$name 脚本绕过了 bossCaptured()，会退化成只读主框架',
        );
        expect(script.contains('bossCaptured'), isTrue, reason: '$name 脚本');
      });
    });

    test('发请求的脚本一律通过 bossCall()，不自己拼 XHR', () {
      // 报文形状、逐层解响应这套模板重复三遍是当初漏修的根源
      for (final name in ['提交', '单日工时', '整月工时', '扫描常量']) {
        final script = allScripts()[name]!;
        final bodyOnly = script
            .replaceAll(sessionBody(), '')
            .replaceAll(BossSessionScript.callPreamble(), '');
        expect(
          bodyOnly.contains('new XMLHttpRequest'),
          isFalse,
          reason: '$name 脚本自己拼了 XHR',
        );
        expect(bodyOnly.contains('bossCall('), isTrue, reason: '$name 脚本');
      }
    });
  });

  group('诊断脚本', () {
    test('按 frame 逐个报告，才能看出数据在哪、我们读的是哪', () {
      final script = WorkLogDiagnosticsScript.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      );

      expect(script.contains('frames'), isTrue);
      expect(script.contains('hooked'), isTrue);
      expect(script.contains('conclusion'), isTrue);
    });

    test('只输出 para 的 key，不输出值', () {
      // 诊断报告会被复制出去发给别人，带上值等于泄露凭据
      final script = WorkLogDiagnosticsScript.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      );

      expect(script.contains('Object.keys(para)'), isTrue);
    });

    test('取样片段必须先给凭据打码', () {
      // 「抓到了但解析失败」时要把原始片段贴出来才能定位形状，
      // 而 BOSS 的请求体里带明文 Password，直接贴等于泄露。
      final script = WorkLogDiagnosticsScript.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      );

      expect(script.contains('function redact('), isTrue);
      // Password/LoginID 只允许作为打码的匹配目标出现，且必须被替换成 ***
      expect(script.contains(r'***'), isTrue);
      expect(script.contains('redact(s.substring('), isTrue);
    });

    test('区分「响应被截断」与「形状不认识」', () {
      // 抓包每条截断在 6000 字符，BOSS 列表响应远大于此。
      // 键名被切掉和正则写错，在最终结果上完全一样，必须能分开。
      final script = WorkLogDiagnosticsScript.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      );

      expect(script.contains('isTruncated'), isTrue);
      expect(script.contains('responseLength'), isTrue);
    });
  });

  group('诊断脚本的服务清单', () {
    test('列出页面调过的每个 ServiceUri 及其响应特征', () {
      // BOSS 所有业务共用一个 DataService 入口，靠 para.ServiceUri 区分。
      // 已知 GetWorkHours 这类无状态服务可直接重放，因此只要知道
      // 「列出我的工作日志」是哪个服务名，就不必再靠扫响应碰运气。
      final script = WorkLogDiagnosticsScript.build(
        captureStoreName: store,
        preferredProjectName: '某项目',
      );

      expect(script.contains('report.services'), isTrue);
      expect(script.contains('serviceUri'), isTrue);
      expect(script.contains('respHasWorkLog'), isTrue);
      expect(script.contains('respHasAuditor'), isTrue);
      expect(script.contains('anyTruncated'), isTrue);
      // 光有服务名不够，还得知道它吃哪些参数才能照着重放
      expect(script.contains('paramKeys'), isTrue);
      // 参数只取 key 不取值：值里可能带 Password
      expect(script.contains('slot.paramKeys.push(ik)'), isTrue);
    });
  });
}
