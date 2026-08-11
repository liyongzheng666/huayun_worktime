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

    test('个人设置优先于业务对象里带出来的', () {
      // 设置项是「当前默认审核人」的权威出处，历史对象可能是旧的
      expect(script.contains('fromSetting || fromField'), isTrue);
    });
  });

  group('解析返回值', () {
    test('取出审核人 ID 与姓名', () {
      final auditor = WorkLogAuditorLookup.parse(
        jsonEncode({'ok': true, 'id': ';USERINFO_ccc', 'name': '张三'}),
      );

      expect(auditor?.id, ';USERINFO_ccc');
      expect(auditor?.name, '张三');
    });

    test('姓名缺失时为空串，不影响 ID', () {
      // 姓名只用于肉眼核对，缺了不该让整条配置作废
      final auditor = WorkLogAuditorLookup.parse(
        jsonEncode({'ok': true, 'id': ';USERINFO_ccc'}),
      );

      expect(auditor?.id, ';USERINFO_ccc');
      expect(auditor?.name, '');
    });

    test('ID 形状不对时当作没取到', () {
      // 拿一个不是审核人的 ID 去提交，日志会发给错误的审批人。
      // 这里宁可返回 null 让上层停下来。
      for (final bad in ['USERINFO_ccc', ';PROJECT_aaa', '', ';USERINFO']) {
        expect(
          WorkLogAuditorLookup.parse(jsonEncode({'ok': true, 'id': bad})),
          isNull,
          reason: '「$bad」不该被当成审核人',
        );
      }
    });

    test('ok 为 false、空值、脏字符串都返回 null 而不是抛异常', () {
      expect(WorkLogAuditorLookup.parse(null), isNull);
      expect(WorkLogAuditorLookup.parse(''), isNull);
      expect(WorkLogAuditorLookup.parse('不是 JSON'), isNull);
      expect(
        WorkLogAuditorLookup.parse(jsonEncode({'ok': false, 'id': ';USERINFO_c'})),
        isNull,
      );
    });
  });

  group('BossAuditor', () {
    test('同 ID 同名视为相等', () {
      expect(
        const BossAuditor(id: ';USERINFO_ccc', name: '张三'),
        const BossAuditor(id: ';USERINFO_ccc', name: '张三'),
      );
    });
  });
}
