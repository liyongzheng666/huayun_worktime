import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';

void main() {
  group('扫描脚本', () {
    final script = WorkLogProjectListLookup.build(captureStoreName: 'store');

    test('只把响应喂给解析器，绝不喂请求体', () {
      // BOSS 把明文 Password 放在每个请求体里；扫请求体等于给凭据泄漏开口子。
      // 注意不能简单断言脚本里不出现 entry.body——公共的 sessionPreamble
      // 带了个读请求体的 bossFindPara（本脚本并不调用它）。
      // 真正要守的是：喂进 walk() 的只能是响应。
      expect(script.contains('walk(entry.response'), isTrue);
      expect(script.contains('walk(entry.body'), isFalse);
    });

    test('只放行 PROJECT_ 开头的标识，凭据无从被当成项目输出', () {
      // 这是输出安全的最终保障：一段文本必须配上一个 PROJECT_ 标识才会被收下，
      // 且它自己不能也是个标识。凭据不满足这个形状，落不进输出。
      expect(script.contains('if (!isProjectId(id)) return;'), isTrue);
      expect(script.contains("v.indexOf('PROJECT_') === 0"), isTrue);
      expect(script.contains("n.indexOf('USERINFO_') === 0"), isTrue);
    });

    test('走统一的会话入口，汇总所有 frame', () {
      // 业务模块跑在 iframe 里，只读主框架永远扫不到项目网格
      expect(script.contains('bossCaptured()'), isTrue);
    });

    test('递归下探有层数上限', () {
      // BOSS 的响应里存在自引用结构，不封顶会栈溢出
      expect(script.contains('MAX_DEPTH'), isTrue);
      expect(script.contains('${WorkLogProjectListLookup.maxDepth}'), isTrue);
    });

    test('四种数据形状都认', () {
      // 都是实际抓包里出现过的形状，少认一种就会整批漏掉
      expect(script.contains('harvestRow'), isTrue, reason: '行内分列（我的项目网格）');
      expect(script.contains('obj.ColName'), isTrue, reason: '同列 ColText/ColValue 配对');
      expect(script.contains('obj.Key'), isTrue, reason: '键值对（项目下拉数据源）');
      expect(script.contains('obj.PROJECTID'), isTrue, reason: '详情对象');
    });

    test('行内分列时按 EID/ENAME/EUID 取值', () {
      // 我的项目网格里 ID 和名字在同一行的不同列对象上，
      // 只认「同一列对象内配对」会让整个网格一条都扫不到
      expect(script.contains("'EID', 'PROJECTID'"), isTrue);
      expect(script.contains("'ENAME', 'PROJECTNAME'"), isTrue);
      expect(script.contains("'EUID', 'PROJECTCODE'"), isTrue);
    });

    test('同一项目从多处扫到时按 id 归并并补齐编码', () {
      // 否则「有名字没编码」和「有编码没名字」会各占一条，
      // 候选列表里出现两个看起来一样的项目
      expect(script.contains('if (!prev.code && c) prev.code = c;'), isTrue);
    });
  });

  group('解析返回值', () {
    test('取出项目名与 ID', () {
      final projects = WorkLogProjectListLookup.parse(
        jsonEncode({
          'ok': true,
          'projects': [
            {'id': 'PROJECT_b', 'name': '乙项目'},
            {'id': 'PROJECT_a', 'name': '甲项目'},
          ],
        }),
      );

      expect(projects.length, 2);
      expect(projects.first.name, '乙项目');
      expect(projects.first.id, 'PROJECT_b');
    });

    test('按名字排序，顺序稳定', () {
      // 抓包顺序会随浏览行为变，输出顺序不能跟着变
      final projects = WorkLogProjectListLookup.parse(
        jsonEncode({
          'ok': true,
          'projects': [
            {'id': 'PROJECT_z', 'name': 'Z项目'},
            {'id': 'PROJECT_a', 'name': 'A项目'},
          ],
        }),
      );

      expect(projects.map((p) => p.name).toList(), ['A项目', 'Z项目']);
    });

    test('丢掉名字或 ID 缺失的条目', () {
      final projects = WorkLogProjectListLookup.parse(
        jsonEncode({
          'ok': true,
          'projects': [
            {'id': 'PROJECT_a', 'name': ''},
            {'id': '', 'name': '没有 ID'},
            {'id': 'PROJECT_c', 'name': '完整的'},
          ],
        }),
      );

      expect(projects.length, 1);
      expect(projects.single.name, '完整的');
    });

    test('ok 为 false、空值、脏字符串都返回空列表而不是抛异常', () {
      // 扫不到项目只是「没有清单」，不该让整条提交链路失败
      expect(
        WorkLogProjectListLookup.parse(jsonEncode({'ok': false})),
        isEmpty,
      );
      expect(WorkLogProjectListLookup.parse(null), isEmpty);
      expect(WorkLogProjectListLookup.parse('不是 JSON'), isEmpty);
      expect(
        WorkLogProjectListLookup.parse(jsonEncode({'ok': true})),
        isEmpty,
      );
    });
  });

  group('BossProject', () {
    test('同名同 ID 视为相等，便于去重', () {
      expect(
        const BossProject(id: 'PROJECT_a', name: '甲'),
        const BossProject(id: 'PROJECT_a', name: '甲'),
      );
      expect(
        const BossProject(id: 'PROJECT_a', name: '甲'),
        isNot(const BossProject(id: 'PROJECT_b', name: '甲')),
      );
    });
  });

  group('项目编码（EUID）', () {
    test('解析时带出 code', () {
      // 日志的 PROJECTCODE 就是项目的 EUID，由实际抓包比对确认
      final projects = WorkLogProjectListLookup.parse(
        jsonEncode({
          'ok': true,
          'projects': [
            {
              'id': 'PROJECT_899dce8a',
              'name': '面向比亚迪公司汽车造型设计场景的工业造型设计软件攻关项目-自筹',
              'code': 'PROJECT_75e02aca',
            },
          ],
        }),
      );

      expect(projects.single.code, 'PROJECT_75e02aca');
    });

    test('缺 code 时为空串而不是 null，不影响其余字段', () {
      final projects = WorkLogProjectListLookup.parse(
        jsonEncode({
          'ok': true,
          'projects': [
            {'id': 'PROJECT_a', 'name': '甲项目'},
          ],
        }),
      );

      expect(projects.single.code, isEmpty);
      expect(projects.single.name, '甲项目');
    });

    test('code 参与相等判定，避免归并后被当成同一条', () {
      expect(
        const BossProject(id: 'PROJECT_a', name: '甲', code: 'PROJECT_x'),
        isNot(const BossProject(id: 'PROJECT_a', name: '甲')),
      );
    });
  });
}
