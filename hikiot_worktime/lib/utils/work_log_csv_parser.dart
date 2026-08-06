/// 工作日志条目（对应导入 CSV 的一行）
class WorkLogEntry {
  const WorkLogEntry({
    required this.date,
    required this.projectName,
    required this.workType,
    required this.stage,
    required this.activity,
    required this.title,
    required this.content,
  });

  /// 日期，yyyy-MM-dd
  final String date;

  /// 项目名称
  final String projectName;

  /// BOSS工作类型
  final String workType;

  /// 项目阶段
  final String stage;

  /// 阶段活动
  final String activity;

  /// 标题
  final String title;

  /// 工作内容
  final String content;

  Map<String, dynamic> toJson() => {
    'date': date,
    'projectName': projectName,
    'workType': workType,
    'stage': stage,
    'activity': activity,
    'title': title,
    'content': content,
  };

  factory WorkLogEntry.fromJson(Map<String, dynamic> json) {
    String read(String key) => (json[key] as String?) ?? '';
    return WorkLogEntry(
      date: read('date'),
      projectName: read('projectName'),
      workType: read('workType'),
      stage: read('stage'),
      activity: read('activity'),
      title: read('title'),
      content: read('content'),
    );
  }

  @override
  String toString() => 'WorkLogEntry($date, $title)';
}

/// CSV 解析异常，携带可直接展示给用户的中文原因。
class WorkLogCsvException implements Exception {
  const WorkLogCsvException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 工作日志 CSV 解析工具
///
/// 单一职责：只负责把 CSV 文本转成 [WorkLogEntry]，不涉及存储和 UI。
/// 自带 RFC4180 解析，因为「工作内容」字段带引号且内含逗号，
/// 简单 split(',') 会把一行拆坏。
class WorkLogCsvParser {
  WorkLogCsvParser._();

  /// 表头到字段的映射。表头缺失时按位置回退，避免导出工具改动列名就整体失败。
  static const List<String> expectedHeaders = [
    '日期',
    '项目名称',
    'BOSS工作类型',
    '项目阶段',
    '阶段活动',
    '标题',
    '工作内容',
  ];

  /// 解析 CSV 文本为按日期归档的条目表。
  ///
  /// 同一天出现多行时，后出现的覆盖先出现的。
  static Map<String, WorkLogEntry> parse(String csvContent) {
    final entries = parseList(csvContent);
    return {for (final entry in entries) entry.date: entry};
  }

  /// 解析 CSV 文本为条目列表，保持原始顺序。
  static List<WorkLogEntry> parseList(String csvContent) {
    final rows = parseRows(csvContent);
    if (rows.isEmpty) {
      throw const WorkLogCsvException('CSV 内容为空');
    }

    final headerIndex = _resolveHeaderIndex(rows.first);
    final entries = <WorkLogEntry>[];

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      // 跳过完全空白行（导出工具常在末尾留一行）
      if (row.every((cell) => cell.trim().isEmpty)) continue;

      String cell(String key) {
        final index = headerIndex[key];
        if (index == null || index >= row.length) return '';
        return row[index].trim();
      }

      final date = _normalizeDate(cell('日期'));
      if (date == null) continue;

      entries.add(
        WorkLogEntry(
          date: date,
          projectName: cell('项目名称'),
          workType: cell('BOSS工作类型'),
          stage: cell('项目阶段'),
          activity: cell('阶段活动'),
          title: cell('标题'),
          content: cell('工作内容'),
        ),
      );
    }

    if (entries.isEmpty) {
      throw const WorkLogCsvException('未解析到任何有效日志行，请检查日期列格式是否为 yyyy-MM-dd');
    }
    return entries;
  }

  /// 建立表头名到列号的映射；表头对不上时按预期顺序回退到位置映射。
  static Map<String, int> _resolveHeaderIndex(List<String> headerRow) {
    final normalized = headerRow
        .map((cell) => cell.replaceAll('﻿', '').trim())
        .toList();
    final index = <String, int>{};

    for (final header in expectedHeaders) {
      final position = normalized.indexOf(header);
      if (position >= 0) index[header] = position;
    }

    // 一个都没匹配上，说明表头被改过或没有表头行，退回按列序读取。
    if (index.isEmpty) {
      for (var i = 0; i < expectedHeaders.length; i++) {
        index[expectedHeaders[i]] = i;
      }
    }
    return index;
  }

  /// 校验并归一化日期，只接受 yyyy-MM-dd。
  static String? _normalizeDate(String raw) {
    if (raw.isEmpty) return null;
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(raw);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    // 借 DateTime 反查，排除 2026-02-30 这类不存在的日期。
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }

    return '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}-'
        '${day.toString().padLeft(2, '0')}';
  }

  /// RFC4180 行列解析。
  ///
  /// 支持：双引号包裹字段、字段内逗号、字段内换行、`""` 转义引号、
  /// CRLF 与 LF 混用、UTF-8 BOM。
  static List<List<String>> parseRows(String csvContent) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;

    // 去掉 UTF-8 BOM，否则第一个表头会带上不可见字符导致匹配失败。
    final text = csvContent.startsWith('﻿')
        ? csvContent.substring(1)
        : csvContent;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];

      if (inQuotes) {
        if (char == '"') {
          // 连续两个引号表示一个字面量引号
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(char);
        }
        continue;
      }

      if (char == '"' && !fieldStarted) {
        inQuotes = true;
        fieldStarted = true;
      } else if (char == ',') {
        endField();
      } else if (char == '\n') {
        endRow();
      } else if (char == '\r') {
        // 单独的 \r 或 \r\n 都视为行结束，\n 在下一轮被跳过
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
        endRow();
      } else {
        field.write(char);
        fieldStarted = true;
      }
    }

    // 收尾：最后一行没有换行符时仍要落盘
    if (field.isNotEmpty || row.isNotEmpty) {
      endRow();
    }

    return rows;
  }
}
