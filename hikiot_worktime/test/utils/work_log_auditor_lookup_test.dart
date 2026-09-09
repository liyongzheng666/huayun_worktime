import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_auditor_lookup.dart';

import '../support/javascript_runner.dart';

void main() {
  List<BossAuditor> scan(
    Object response, {
    Object? requestBody,
    String pageSetup = '',
    String projectId = '',
  }) {
    final script = WorkLogAuditorLookup.build(
      captureStoreName: 'store',
      projectId: projectId,
    );
    final result = runJavaScript('''
      const window = {frames: [], store: [{
        response: ${jsonEncode(response)},
        body: ${jsonEncode(requestBody)}
      }]};
      $pageSetup
      const result = $script
      console.log(JSON.stringify(result));
    ''');
    return WorkLogAuditorLookup.parse(result as String);
  }

  group('实际执行审核人扫描脚本', () {
    final setting = {
      'auditor': ';USERINFO_default',
      'auditorText': '默认审核人',
      'focusor': ';USERINFO_observer',
      'focusorText': '关注人',
    };

    test('登录响应的真实 ENAME 和 SETTINGVALUE 形状保留设置来源', () {
      expect(
        scan({
          'SystemSettings': jsonEncode([
            {
              'ENAME': WorkLogAuditorLookup.settingKey,
              'SETTINGVALUE': jsonEncode(setting),
            },
          ]),
        }),
        [
          const BossAuditor(
            id: ';USERINFO_default',
            name: '默认审核人',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });

    test('只在网页内存中的个人设置也可读取且不需要历史响应', () {
      expect(
        scan(
          {},
          pageSetup:
              '''
        window.frames.push({frames: [], HoteamUI: {Common: {
          GetPersonalSetting(key) {
            if (key !== ${jsonEncode(WorkLogAuditorLookup.settingKey)}) {
              throw new Error('读取了无关设置');
            }
            return ${jsonEncode(jsonEncode(setting))};
          }
        }}});
      ''',
        ),
        [
          const BossAuditor(
            id: ';USERINFO_default',
            name: '默认审核人',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });

    test('复用网页专用只读查询，基础与项目审核人归并且服务来源优先', () {
      expect(
        scan(
          {WorkLogAuditorLookup.settingKey: setting},
          projectId: 'PROJECT_example',
          pageSetup: '''
          let calls = 0;
          const ui = {DataService: {Call(service, args) {
            if (service !== 'Hoteam.InforCenter.WorkReportService.GetWorkLogAuditor') {
              throw new Error('调用了无关接口');
            }
            calls++;
            if (calls > 2) throw new Error('重复 frame 查询');
            if (JSON.stringify(args) === JSON.stringify({para: {UseLast: true}})) {
              return [{Value: 'USERINFO_default', Text: '当前审核人'}];
            }
            if (JSON.stringify(args) === JSON.stringify({
              para: {UseLast: true, ProjectID: 'PROJECT_example'}
            })) {
              return [{Value: 'USERINFO_manager', Text: '项目经理'}];
            }
            throw new Error('参数与网页调用不一致');
          }}};
          window.HoteamUI = ui;
          window.frames.push({frames: [], HoteamUI: ui});
          process.on('exit', () => {
            if (calls !== 2) throw new Error('查询次数不正确: ' + calls);
          });
        ''',
        ),
        containsAll([
          const BossAuditor(
            id: ';USERINFO_default',
            name: '当前审核人',
            source: BossAuditorSource.service,
          ),
          const BossAuditor(
            id: ';USERINFO_manager',
            name: '项目经理',
            source: BossAuditorSource.service,
          ),
        ]),
      );
    });

    test('查询失败时仍可从网页设置取审核人', () {
      expect(
        scan(
          {},
          pageSetup:
              '''
        window.HoteamUI = {
          Common: {GetPersonalSetting() { return ${jsonEncode(setting)}; }},
          DataService: {Call() { throw new Error('查询失败'); }}
        };
      ''',
        ),
        [
          const BossAuditor(
            id: ';USERINFO_default',
            name: '默认审核人',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });

    test('默认设置经过两层 JSON 编码仍能识别并保留设置来源', () {
      expect(
        scan({
          WorkLogAuditorLookup.settingKey: jsonEncode(jsonEncode(setting)),
        }),
        [
          const BossAuditor(
            id: ';USERINFO_default',
            name: '默认审核人',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });

    test('设置值内的响应包装解开后仍是默认审核人', () {
      expect(
        scan({
          'Key': WorkLogAuditorLookup.settingKey,
          'Value': jsonEncode({'d': jsonEncode(setting)}),
        }),
        [
          const BossAuditor(
            id: ';USERINFO_default',
            name: '默认审核人',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });

    test('历史网格同一行的姓名列与原始 ID 伴生列配对', () {
      expect(
        scan({
          'Rows': [
            [
              {'ColName': 'AUDITOR', 'ColText': '张三', 'ColValue': null},
              {
                'ColName': r'AUDITOR$DBValue',
                'ColText': 'USERINFO_zhang',
                'ColValue': null,
              },
            ],
            [
              {
                'ColName': 'AUDITOR',
                'ColText': '李四',
                'ColValue': 'USERINFO_li',
              },
            ],
          ],
        }),
        containsAll([
          const BossAuditor(id: ';USERINFO_zhang', name: '张三'),
          const BossAuditor(id: ';USERINFO_li', name: '李四'),
        ]),
      );
    });

    test('不把另一行的姓名配给只有 ID 的审核人', () {
      expect(
        scan({
          'Rows': [
            [
              {'ColName': 'AUDITOR', 'ColText': '其他人', 'ColValue': null},
            ],
            [
              {
                'ColName': r'AUDITOR$DBValue',
                'ColText': 'USERINFO_unknown',
                'ColValue': null,
              },
            ],
          ],
        }),
        [const BossAuditor(id: ';USERINFO_unknown')],
      );
    });

    test('带分号的审核人 ID 不作为姓名展示', () {
      expect(
        scan({
          'auditor': ';USERINFO_unknown',
          'auditorText': ';USERINFO_unknown',
        }),
        [const BossAuditor(id: ';USERINFO_unknown')],
      );
    });

    test('不从请求体、填报人或关注人字段误收审核人', () {
      expect(
        scan({
          'CREATOR': 'USERINFO_creator',
          'focusor': ';USERINFO_observer',
          'UserID': 'USERINFO_self',
        }, requestBody: jsonEncode({'auditor': ';USERINFO_request'})),
        isEmpty,
      );
    });

    test('设置优先级与历史姓名补全合并到同一个 ID', () {
      expect(
        scan({
          WorkLogAuditorLookup.settingKey: {'auditor': ';USERINFO_zhang'},
          'history': {'AUDITOR': 'USERINFO_zhang', 'AUDITORNAME': '张三'},
        }),
        [
          const BossAuditor(
            id: ';USERINFO_zhang',
            name: '张三',
            source: BossAuditorSource.setting,
          ),
        ],
      );
    });
  });

  group('扫描脚本', () {
    final script = WorkLogAuditorLookup.build(captureStoreName: 'store');

    test('只把响应喂给遍历器，绝不喂请求体', () {
      // BOSS 把明文 Password 放在每个请求体里，扫请求体等于给凭据泄漏开口子
      expect(script.contains('bossWalk(entry.response'), isTrue);
      expect(script.contains('bossWalk(entry.body'), isFalse);
    });

    test('走统一的会话入口，汇总所有 frame', () {
      // 业务模块跑在 iframe 里，只读主框架永远扫不到设置项
      expect(script.contains('bossCaptured()'), isTrue);
    });

    test('认 BOSS 那个拼错的键名', () {
      // 系统设置里就写作 AudtiorFocusor（Auditor 拼错了），
      // 顺手「改对」会让整条路直接失效
      expect(script.contains('AudtiorFocusor'), isTrue);
      // 将来他们改回正确拼写也不至于断掉
      expect(script.contains('AuditorFocusor'), isTrue);
    });

    test('只认键名本身就是审核人的字段，不做 USERINFO_ 前缀碰运气', () {
      // 抓包里别处的 USERINFO_ 往往是用户自己的 ID；
      // 认错了会把日志提交给错误的审批人
      expect(script.contains('obj.auditor'), isTrue);
      expect(script.contains('obj.AUDITOR'), isTrue);
      // 没有「见到 USERINFO_ 就收下」这种写法
      expect(
        script.contains("indexOf('USERINFO_') >= 0"),
        isFalse,
        reason: '不得靠前缀出现与否来判定审核人',
      );
    });

    test('认历史日志网格里的 AUDITOR 列', () {
      // 网格里 ID 在 ColValue、姓名在 ColText，这是最容易抓到的一种形状，
      // 早先漏掉了它
      expect(script.contains("obj.ColName === 'AUDITOR'"), isTrue);
    });

    test('同一个人从多处扫到时归并，来源就高不就低', () {
      // 否则候选列表里会出现两条看起来一样的
      expect(script.contains("prev.source = 'setting'"), isTrue);
    });
  });

  /// 造一条脚本返回值。
  String payload(List<Map<String, dynamic>> auditors) =>
      jsonEncode({'ok': true, 'auditors': auditors});

  group('解析返回值', () {
    test('取出审核人 ID、姓名与来源', () {
      final list = WorkLogAuditorLookup.parse(
        payload([
          {'id': ';USERINFO_ccc', 'name': '张三', 'source': 'setting'},
        ]),
      );

      expect(list.single.id, ';USERINFO_ccc');
      expect(list.single.name, '张三');
      expect(list.single.source, BossAuditorSource.setting);
    });

    test('当前服务优先于个人设置，同一来源有姓名的排前面', () {
      final list = WorkLogAuditorLookup.parse(
        payload([
          {'id': ';USERINFO_a', 'name': '', 'source': 'field'},
          {'id': ';USERINFO_b', 'name': '李四', 'source': 'field'},
          {'id': ';USERINFO_c', 'name': '张三', 'source': 'setting'},
          {'id': ';USERINFO_d', 'name': '当前审核人', 'source': 'service'},
        ]),
      );

      expect(list.map((a) => a.id).toList(), [
        ';USERINFO_d',
        ';USERINFO_c',
        ';USERINFO_b',
        ';USERINFO_a',
      ]);
    });

    test('姓名缺失时为空串，仍然保留为候选', () {
      // 姓名只用于肉眼核对，缺了不该让这条候选整个消失——
      // 界面会显示「（没扫到姓名）」，由用户判断
      final list = WorkLogAuditorLookup.parse(
        payload([
          {'id': ';USERINFO_ccc'},
        ]),
      );

      expect(list.single.id, ';USERINFO_ccc');
      expect(list.single.name, '');
    });

    test('ID 形状不对的一律丢掉', () {
      // 拿一个不是审核人的 ID 去提交，日志会发给错误的审批人
      final list = WorkLogAuditorLookup.parse(
        payload([
          {'id': 'USERINFO_ccc'},
          {'id': ';PROJECT_aaa'},
          {'id': ''},
          {'id': ';USERINFO'},
        ]),
      );

      expect(list, isEmpty);
    });

    test('ok 为 false、空值、脏字符串都返回空列表而不是抛异常', () {
      expect(WorkLogAuditorLookup.parse(null), isEmpty);
      expect(WorkLogAuditorLookup.parse(''), isEmpty);
      expect(WorkLogAuditorLookup.parse('不是 JSON'), isEmpty);
      expect(
        WorkLogAuditorLookup.parse(
          jsonEncode({
            'ok': false,
            'auditors': [
              {'id': ';USERINFO_c'},
            ],
          }),
        ),
        isEmpty,
      );
    });
  });

  group('BossAuditor', () {
    test('同 ID 同名同来源视为相等', () {
      expect(
        const BossAuditor(id: ';USERINFO_ccc', name: '张三'),
        const BossAuditor(id: ';USERINFO_ccc', name: '张三'),
      );
    });

    test('来源有给用户看的说明，且不宣称「就是它」', () {
      expect(BossAuditorSource.setting.label, contains('默认审核人'));
      expect(BossAuditorSource.field.label, contains('出现在'));
    });
  });
}
