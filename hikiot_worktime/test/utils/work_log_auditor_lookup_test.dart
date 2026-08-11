import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_auditor_lookup.dart';

void main() {
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

    test('个人设置的排最前，其次是有姓名的', () {
      // 设置项是「当前默认审核人」的权威出处；没名字的没法核对，排后面
      final list = WorkLogAuditorLookup.parse(
        payload([
          {'id': ';USERINFO_a', 'name': '', 'source': 'field'},
          {'id': ';USERINFO_b', 'name': '李四', 'source': 'field'},
          {'id': ';USERINFO_c', 'name': '张三', 'source': 'setting'},
        ]),
      );

      expect(list.map((a) => a.id).toList(), [
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
