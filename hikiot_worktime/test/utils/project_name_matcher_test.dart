import 'package:flutter_test/flutter_test.dart';
import 'package:hikiot_worktime/utils/project_name_matcher.dart';
import 'package:hikiot_worktime/utils/work_log_project_list_lookup.dart';

const _csv = '面向比亚迪公司的项目-自筹';
const _boss = '面向比亚迪公司的项目-自筹(2)';

BossProject p(String name, [String id = 'PROJECT_x']) =>
    BossProject(id: id, name: name);

void main() {
  group('归一化', () {
    test('去掉空白', () {
      expect(ProjectNameMatcher.normalize(' 某 项目 '), '某项目');
    });

    test('全角转半角', () {
      expect(ProjectNameMatcher.normalize('某项目（２）'), '某项目(2)');
      expect(ProjectNameMatcher.normalize('ＡＢＣ'), 'ABC');
    });

    test('绝不去掉括号内容', () {
      // 「(2)」很可能正是区分两个项目的唯一标记。抹掉它会让两个不同项目
      // 归一化后完全相同，被判成最高一档——那正是这套机制要防的事
      expect(
        ProjectNameMatcher.normalize(_boss),
        isNot(ProjectNameMatcher.normalize(_csv)),
      );
      expect(ProjectNameMatcher.normalize('某项目(2)'), contains('(2)'));
    });
  });

  group('匹配分档', () {
    test('完全相同', () {
      final m = ProjectNameMatcher.score(p(_csv), _csv);
      expect(m.level, ProjectMatchLevel.exact);
      expect(m.score, 1);
    });

    test('只差空格或全半角算「归一化后相同」', () {
      expect(
        ProjectNameMatcher.score(p('某 项目（２）'), '某项目(2)').level,
        ProjectMatchLevel.normalized,
      );
    });

    test('CSV 少一个「(2)」判为包含关系，而不是完全相同', () {
      // 这是用户的实际情况。判成 exact/normalized 就等于替他断定是同一个项目
      final m = ProjectNameMatcher.score(p(_boss), _csv);
      expect(m.level, ProjectMatchLevel.contains);
      expect(m.score, lessThan(1));
    });

    test('毫不相干的项目判为差别较大', () {
      expect(
        ProjectNameMatcher.score(p('运维平台三期'), _csv).level,
        ProjectMatchLevel.weak,
      );
    });

    test('每一档都有给用户看的说明，不暴露分数', () {
      for (final level in ProjectMatchLevel.values) {
        expect(level.label, isNotEmpty);
        expect(level.label, isNot(contains('0.')));
      }
    });
  });

  group('排序', () {
    test('完全相同的排在包含关系之前', () {
      final ranked = ProjectNameMatcher.rank([
        p(_boss, 'PROJECT_b'),
        p(_csv, 'PROJECT_a'),
      ], _csv);

      expect(ranked.first.project.id, 'PROJECT_a');
      expect(ranked.first.level, ProjectMatchLevel.exact);
    });

    test('包含关系排在不相干项目之前', () {
      final ranked = ProjectNameMatcher.rank([
        p('运维平台三期', 'PROJECT_c'),
        p(_boss, 'PROJECT_b'),
      ], _csv);

      expect(ranked.first.project.id, 'PROJECT_b');
    });

    test('多出来的部分越短，排得越前', () {
      // 「-自筹(2)」比「-自筹(2)(历史归档)」更可能只是个后缀
      final ranked = ProjectNameMatcher.rank([
        p('$_csv(2)(历史归档存档版)', 'PROJECT_long'),
        p('$_csv(2)', 'PROJECT_short'),
      ], _csv);

      expect(ranked.first.project.id, 'PROJECT_short');
    });

    test('分数相同时按名字排，保证顺序稳定', () {
      // 抓包顺序随用户浏览行为变；每次弹出来顺序都不同的列表没法建立肌肉记忆
      final ranked = ProjectNameMatcher.rank([
        p('乙项目', 'PROJECT_2'),
        p('甲项目', 'PROJECT_1'),
      ], '完全无关的名字');

      expect(
        ranked.map((m) => m.project.name).toList(),
        ['乙项目', '甲项目']..sort(),
      );
    });

    test('空清单返回空，不炸', () {
      expect(ProjectNameMatcher.rank(const [], _csv), isEmpty);
    });
  });

  group('相似度', () {
    test('完全相同为 1，毫无交集为 0', () {
      expect(ProjectNameMatcher.similarity('abc', 'abc'), 1);
      expect(ProjectNameMatcher.similarity('abc', 'xyz'), 0);
    });

    test('空串不会导致除零', () {
      expect(ProjectNameMatcher.similarity('', ''), 1);
      expect(ProjectNameMatcher.similarity('abc', ''), 0);
    });

    test('最长公共子序列允许中间有插入', () {
      expect(ProjectNameMatcher.lcsLength('甲乙丙', '甲X乙X丙'), 3);
    });
  });
}
