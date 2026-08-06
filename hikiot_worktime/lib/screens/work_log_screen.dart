import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/theme.dart';
import '../services/storage_service.dart';
import '../services/work_log_repository.dart';
import '../utils/date_helper.dart';
import '../utils/haptic_utils.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_time_calculator.dart';
import '../widgets/boss_constants_dialog.dart';
import 'work_report_webview_screen.dart';

/// 工作日志填报页
///
/// 职责：展示某一天的填报素材（CSV 内容 + 实际打卡工时），并提供一键复制。
/// 解析、存储、工时合并全部在 [WorkLogRepository]，本页只做展示与交互。
class WorkLogScreen extends StatefulWidget {
  const WorkLogScreen({super.key});

  @override
  State<WorkLogScreen> createState() => WorkLogScreenState();
}

class WorkLogScreenState extends State<WorkLogScreen> {
  final WorkLogRepository _repository = WorkLogRepository();

  DateTime _selectedDate = DateHelper.getWorkDate();
  WorkLogDraft? _draft;
  String? _sourceName;
  DateTime? _importedAt;
  int _totalCount = 0;
  bool _loading = true;

  /// BOSS 提交配置是否已就绪。未就绪时提交必然失败，因此在界面上前置提示。
  bool _bossConfigured = false;

  /// 加载序号。切换日期会发起新的工时请求，而先发的请求可能后返回，
  /// 不做丢弃就会出现「日期栏显示 8-7、内容却是 8-6」的错位。
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 供外部（主框架切换 tab 时）触发刷新。
  Future<void> refreshData() => _reload();

  Future<void> _reload() async {
    final seq = ++_loadSeq;
    setState(() => _loading = true);

    // 固定本次要加载的日期：等待期间用户可能又翻了一页
    final date = _selectedDate;
    final draft = await _repository.loadDraft(date);
    final (sourceName, importedAt) = await _repository.loadMeta();
    final all = await _repository.loadAll();
    final constants = await StorageService().loadBossConstants();

    // 已经有更新的一次加载在跑，本次结果作废
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _draft = draft;
      _sourceName = sourceName;
      _importedAt = importedAt;
      _totalCount = all.length;
      _bossConfigured = constants['projectId']?.isNotEmpty == true;
      _loading = false;
    });
  }

  Future<void> _changeDate(int deltaDays) async {
    HapticUtils.selectionClick();
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: deltaDays));
    });
    await _reload();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
    await _reload();
  }

  /// 导入 CSV。
  ///
  /// 读文件字节而非路径文本，是为了在解析前显式按 UTF-8 解码，
  /// 避免不同导出工具带 BOM 或系统默认编码不一致导致中文乱码。
  Future<void> _importCsv() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      final bytes =
          picked.bytes ??
          (picked.path != null ? await File(picked.path!).readAsBytes() : null);
      if (bytes == null) {
        _showMessage('读取文件失败');
        return;
      }

      final content = utf8.decode(bytes, allowMalformed: true);
      final imported = await _repository.importFromCsv(
        content,
        sourceName: picked.name,
      );

      await _reload();
      if (!mounted) return;
      _showMessage(
        '已导入 ${imported.importedCount} 条'
        '（${imported.firstDate} ~ ${imported.lastDate}）',
      );
    } on WorkLogCsvException catch (e) {
      _showMessage('导入失败：${e.message}');
    } catch (e) {
      _showMessage('导入失败：$e');
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    HapticUtils.lightImpact();
    if (!mounted) return;
    _showMessage('已复制$label');
  }

  /// 编辑 BOSS 提交配置。
  ///
  /// 关掉对话框后一律以存储为准重新判定，而不是只在「保存」时置位——
  /// 对话框里也可以清除配置，只认保存的话清除后引导卡片不会重新出现。
  Future<void> _editBossConstants() async {
    final saved = await BossConstantsDialog.show(context);
    final constants = await StorageService().loadBossConstants();
    if (!mounted) return;

    setState(() {
      _bossConfigured = constants['projectId']?.isNotEmpty == true;
    });
    if (saved) _showMessage('配置已保存，现在可以一键提交了');
  }

  /// 打开日志系统。
  ///
  /// [autoSubmit] 为 true 时进入后自动等待登录完成并发起提交，
  /// 用户无需手动导航到填报页——提交走报文，与页面停在哪无关。
  Future<void> _openReportSystem({required bool autoSubmit}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkReportWebViewScreen(
          fillDate: _selectedDate,
          autoSubmit: autoSubmit,
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作日志'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'BOSS 提交配置',
            onPressed: _editBossConstants,
          ),
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: '导入 CSV',
            onPressed: _importCsv,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (!_bossConfigured) ...[
                    _buildConfigPrompt(),
                    const SizedBox(height: 12),
                  ],
                  _buildImportCard(),
                  const SizedBox(height: 12),
                  _buildDateBar(),
                  const SizedBox(height: 12),
                  _buildHoursCard(),
                  const SizedBox(height: 12),
                  _buildEntryCard(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'openWeb',
            tooltip: '打开日志系统',
            onPressed: () => _openReportSystem(autoSubmit: false),
            child: const Icon(Icons.open_in_browser),
          ),
          const SizedBox(height: 10),
          // 主入口：打开后自动等登录完成并提交，不用手动翻到填报页
          FloatingActionButton.extended(
            heroTag: 'oneTapSubmit',
            onPressed: _draft?.hasEntry == true
                ? () => _openReportSystem(autoSubmit: true)
                : null,
            backgroundColor: _draft?.hasEntry == true ? null : Colors.grey,
            icon: const Icon(Icons.rocket_launch),
            label: const Text('一键提交'),
          ),
        ],
      ),
    );
  }

  /// BOSS 提交配置未就绪时的引导卡片。
  ///
  /// 刻意**不**把「手工填三个 ID」当主入口：用户没有义务知道
  /// `PROJECT_xxxxxxxx` 是什么，更没义务去哪里翻出来。正常打开一次日志系统，
  /// APP 会在后台从网页会话里自己学到。手工填写只作为学不到时的兜底。
  Widget _buildConfigPrompt() {
    return Card(
      color: AppColors.warningLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.warning),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_fix_high, color: AppColors.warningDark),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BOSS 提交配置未就绪',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.warningDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '打开日志系统并登录，APP 会自动获取，无需手工填写',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warningDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _editBossConstants,
                  child: const Text('手工填写', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: () => _openReportSystem(autoSubmit: false),
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: const Text('打开日志系统', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportCard() {
    final hasData = _totalCount > 0;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              hasData ? Icons.description : Icons.upload_file,
              color: hasData ? Colors.teal : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasData ? '已导入 $_totalCount 条日志' : '尚未导入日志 CSV',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasData
                        ? '${_sourceName ?? '未知文件'}'
                              '${_importedAt == null ? '' : ' · ${DateHelper.formatDate(_importedAt!)}'}'
                        : '点右上角导入按钮选择 CSV 文件',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _importCsv, child: const Text('导入')),
          ],
        ),
      ),
    );
  }

  Widget _buildDateBar() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _changeDate(-1),
            ),
            Expanded(
              child: InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    DateHelper.formatDateChinese(_selectedDate),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _changeDate(1),
            ),
          ],
        ),
      ),
    );
  }

  /// 工作时长卡片，数据来自打卡记录，与「每日工时」页同一口径。
  Widget _buildHoursCard() {
    final hours = _draft?.hours;
    final hasHours = hours?.hasData == true;
    // 复用工时计算器的格式化规则（浮点截断两位，不四舍五入）。
    final display = hasHours
        ? WorkTimeCalculator.formatHours(hours!.hours!)
        : '未获取到';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              Icons.timer_outlined,
              color: hasHours ? Colors.indigo : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '工作时长',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    display,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: hasHours ? Colors.indigo : Colors.grey,
                    ),
                  ),
                  if (hasHours &&
                      (hours!.checkIn != null || hours.checkOut != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${hours.checkIn ?? '-'} ~ ${hours.checkOut ?? '-'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (hasHours)
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: '复制工作时长',
                onPressed: () => _copy('工作时长', display),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryCard() {
    final entry = _draft?.entry;

    if (entry == null) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.event_busy, size: 36, color: Colors.grey[400]),
              const SizedBox(height: 10),
              Text(
                _totalCount == 0
                    ? '请先导入日志 CSV'
                    : 'CSV 中没有 ${_draft?.date ?? ''} 的记录',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            _buildField('标题', entry.title),
            _buildField('工作内容', entry.content, multiline: true),
            _buildField('项目名称', entry.projectName),
            _buildField('BOSS工作类型', entry.workType),
            _buildField('项目阶段', entry.stage),
            _buildField('阶段活动', entry.activity),
          ],
        ),
      ),
    );
  }

  Widget _buildField(String label, String value, {bool multiline = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 3),
                Text(
                  value.isEmpty ? '-' : value,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                  maxLines: multiline ? null : 2,
                  overflow: multiline ? null : TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制$label',
            visualDensity: VisualDensity.compact,
            onPressed: value.isEmpty ? null : () => _copy(label, value),
          ),
        ],
      ),
    );
  }
}
