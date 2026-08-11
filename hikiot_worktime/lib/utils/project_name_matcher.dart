import 'work_log_project_list_lookup.dart';

/// CSV 项目名与 BOSS 项目名的匹配程度
///
/// 分档而不是只给一个分数：分数会让人误以为它是概率，而这里的判断
/// 本质上不是概率——「XX平台」和「XX平台(2)」是不是同一个项目，
/// 只有用户知道。分档能把「完全相同」和「看着像」明确区分开。
enum ProjectMatchLevel {
  /// 一模一样
  exact,

  /// 去掉空白、全角转半角之后相同
  normalized,

  /// 一方是另一方的子串（典型：CSV 少写了「(2)」）
  contains,

  /// 字符层面接近
  similar,

  /// 基本不像
  weak,
}

extension ProjectMatchLevelLabel on ProjectMatchLevel {
  /// 给用户看的说明。措辞刻意保守：除了完全相同，其余都不宣称「就是它」。
  String get label => switch (this) {
    ProjectMatchLevel.exact => '名称完全相同',
    ProjectMatchLevel.normalized => '仅空格或全半角不同',
    ProjectMatchLevel.contains => '名称包含关系，可能是同一项目',
    ProjectMatchLevel.similar => '名称相近',
    ProjectMatchLevel.weak => '名称差别较大',
  };
}

/// 一个候选项目及其匹配结果
class ProjectMatch {
  const ProjectMatch({
    required this.project,
    required this.level,
    required this.score,
  });

  final BossProject project;
  final ProjectMatchLevel level;

  /// 仅用于排序的 0~1 分值，不对外表达为「把握有多大」
  final double score;
}

/// 把 BOSS 项目按与 CSV 项目名的接近程度排序
///
/// **只用于排候选顺序，不用于自动选定。** 「XX平台」与「XX平台(2)」既可能是
/// 同一项目的二期，也可能是两个独立项目；让算法替用户判，等于把
/// 「静默绑错项目」换个更聪明的外衣重来一遍，而且更难被发现——
/// 因为它看起来有理有据。最终必须由用户确认。
class ProjectNameMatcher {
  ProjectNameMatcher._();

  /// 归一化：去掉所有空白，全角字符转半角。
  ///
  /// **刻意不去掉括号及其内容**。「(2)」很可能正是区分两个项目的唯一标记，
  /// 抹掉它会让两个不同的项目归一化后完全相同，从而被判成最高一档——
  /// 那正是这套机制要防的事。
  static String normalize(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      // 全角空格
      if (rune == 0x3000) continue;
      // 半角空白
      if (rune <= 0x20) continue;

      // 全角 ！(0xFF01) ~ ～(0xFF5E) 对应半角 !(0x21) ~ ~(0x7E)
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
        continue;
      }
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  /// 最长公共子序列长度。项目名很短，O(n·m) 完全够用。
  static int lcsLength(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;

    // 只保留两行，避免为长名字分配整张表
    var prev = List<int>.filled(b.length + 1, 0);
    var curr = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
          curr[j] = prev[j - 1] + 1;
        } else {
          curr[j] = curr[j - 1] > prev[j] ? curr[j - 1] : prev[j];
        }
      }
      final swap = prev;
      prev = curr;
      curr = swap;
      curr.fillRange(0, curr.length, 0);
    }
    return prev[b.length];
  }

  /// 字符层面的相似度，0~1。
  static double similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    return 2 * lcsLength(a, b) / (a.length + b.length);
  }

  /// 评一个候选。
  static ProjectMatch score(BossProject project, String csvProjectName) {
    final a = csvProjectName;
    final b = project.name;

    if (a.isNotEmpty && a == b) {
      return ProjectMatch(
        project: project,
        level: ProjectMatchLevel.exact,
        score: 1,
      );
    }

    final na = normalize(a);
    final nb = normalize(b);
    if (na.isNotEmpty && na == nb) {
      return ProjectMatch(
        project: project,
        level: ProjectMatchLevel.normalized,
        score: 0.95,
      );
    }

    final sim = similarity(na, nb);

    if (na.isNotEmpty && nb.isNotEmpty && (nb.contains(na) || na.contains(nb))) {
      // 长度越接近，多出来的那截越可能只是个后缀而非另一个项目
      return ProjectMatch(
        project: project,
        level: ProjectMatchLevel.contains,
        score: 0.7 + 0.2 * sim,
      );
    }

    return ProjectMatch(
      project: project,
      level: sim >= 0.6 ? ProjectMatchLevel.similar : ProjectMatchLevel.weak,
      score: sim * 0.6,
    );
  }

  /// 按接近程度从高到低排序。
  ///
  /// 分数相同时按项目名排，保证顺序稳定——同一份数据每次弹出来
  /// 顺序都不一样的列表，用户没法建立肌肉记忆。
  static List<ProjectMatch> rank(
    List<BossProject> projects,
    String csvProjectName,
  ) {
    final matches = projects.map((p) => score(p, csvProjectName)).toList();
    matches.sort((x, y) {
      final byScore = y.score.compareTo(x.score);
      if (byScore != 0) return byScore;
      return x.project.name.compareTo(y.project.name);
    });
    return matches;
  }
}
