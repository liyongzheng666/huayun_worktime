import 'dart:async';
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
import '../utils/work_log_edit_script.dart';
import '../utils/work_log_auditor_lookup.dart';
import '../utils/work_log_project_list_lookup.dart';
import '../utils/work_time_calculator.dart';
import '../services/boss_session_runner.dart';
import '../services/boss_login_coordinator.dart';
import '../services/boss_hours_auto_refresh_service.dart';
import '../services/work_log_submit_service.dart';
import '../widgets/boss_constants_dialog.dart';
import '../widgets/work_log_auditor_picker_dialog.dart';
import '../widgets/work_log_project_picker_dialog.dart';
import '../widgets/work_log_confirm_dialog.dart';
import '../widgets/work_log_edit_dialog.dart';
import '../widgets/week_strip.dart';
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
  final BossHoursAutoRefreshService _bossAutoRefresh =
      BossHoursAutoRefreshService.shared;
  final GlobalKey<WeekStripState> _weekStripKey = GlobalKey();

  DateTime _selectedDate = DateHelper.getWorkDate();
  WorkLogDraft? _draft;
  String? _sourceName;
  DateTime? _importedAt;
  int _totalCount = 0;
  bool _loading = true;

  /// App 创建成功后记住的 BOSS 记录 ID；有它才能保证编辑的是原记录。
  String? _submittedObjectId;
  BossWorkLogRecord? _submittedRecord;
  bool _editingSubmitted = false;

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

  /// 缓存过期时静默刷新所选日期所在月；失败不提示、不覆盖旧数据。
  Future<void> refreshBossHoursSilently({DateTime? date}) async {
    final target = date ?? _selectedDate;
    final monthKey = DateHelper.formatMonth(target);
    final result = await _bossAutoRefresh.refreshIfStale(target);
    if (!mounted || result.status != BossHoursAutoRefreshStatus.updated) return;
    if (DateHelper.formatMonth(_selectedDate) != monthKey) return;
    _weekStripKey.currentState?.refresh();
  }

  Future<void> _reload() async {
    final seq = ++_loadSeq;
    setState(() => _loading = true);

    // 固定本次要加载的日期：等待期间用户可能又翻了一页
    final date = _selectedDate;
    final draft = await _repository.loadDraft(date);
    final (sourceName, importedAt) = await _repository.loadMeta();
    final all = await _repository.loadAll();
    final constants = await StorageService().loadBossConstants();
    final submittedObjectId = await StorageService().loadWorkLogObjectId(
      DateHelper.formatDate(date),
    );

    // 已经有更新的一次加载在跑，本次结果作废
    if (!mounted || seq != _loadSeq) return;

    // CSV 可能刚被导入、日志可能刚提交，周条上的状态点要跟着更新
    _weekStripKey.currentState?.refresh();
    setState(() {
      _draft = draft;
      _sourceName = sourceName;
      _importedAt = importedAt;
      _totalCount = all.length;
      _bossConfigured = constants['projectId']?.isNotEmpty == true;
      if (_submittedObjectId != submittedObjectId) _submittedRecord = null;
      _submittedObjectId = submittedObjectId;
      _loading = false;
    });
    unawaited(refreshBossHoursSilently(date: date));
  }

  /// 周条选中某一天。
  Future<void> _selectDate(DateTime date) async {
    if (DateHelper.formatDate(date) == DateHelper.formatDate(_selectedDate)) {
      return;
    }
    setState(() => _selectedDate = date);
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

  /// 打开日志系统网页（登录、查看、排查用）。
  Future<void> _openReportSystem({bool autoSubmit = false}) async {
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

  /// 提交互斥锁。BOSS 不做幂等校验，重复提交会静默产生重复日志。
  bool _submitting = false;

  /// 就地提交当天日志，**不跳转网页**。
  ///
  /// 提交必须在 BOSS 网页会话里发（凭据在页面请求体内，不能落到 APP，
  /// 见 docs/踩坑记录.md 3.12），但那是实现约束——用户点的是「提交日志」，
  /// 没道理让他看着网页跳进跳出。这里走后台无头会话，只在真的没登录时
  /// 才引导去网页登录一次。
  Future<void> _submitLog() async {
    if (_submitting) {
      _showMessage('正在提交中，请稍候');
      return;
    }

    final draft = _draft;
    final entry = draft?.entry;
    if (entry == null) {
      _showMessage('CSV 中没有这一天的记录');
      return;
    }

    _submitting = true;
    setState(() {});
    try {
      await _runHeadlessSubmit(entry, draft!);
    } finally {
      _submitting = false;
      if (mounted) setState(() {});
    }
  }

  /// 读取并编辑 App 创建过的那条 BOSS 日志。
  Future<void> _editSubmittedLog() async {
    final objectId = _submittedObjectId;
    if (objectId == null || _editingSubmitted || _submitting) return;

    _editingSubmitted = true;
    if (mounted) setState(() {});
    try {
      _showMessage('正在读取 BOSS 已提交日志…');
      Future<BossSessionResult<BossWorkLogRecord>> loadRecord() {
        return BossSessionRunner.run<BossWorkLogRecord>((controller) {
          return WorkLogSubmitService(controller).loadSubmittedLog(objectId);
        });
      }

      var loaded = await loadRecord();
      if (!mounted) return;
      if (loaded.status == BossSessionStatus.noSession) {
        if (!await _promptBossLogin() || !mounted) return;
        loaded = await loadRecord();
        if (!mounted) return;
      }
      final record = loaded.value;
      if (!loaded.isOk || record == null) {
        _showMessage('未能读取原日志，本次不会修改，请稍后重试');
        return;
      }

      setState(() => _submittedRecord = record);
      final edited = await WorkLogEditDialog.show(
        context: context,
        record: record,
      );
      if (edited == null || !mounted) return;

      _showMessage('正在保存修改…');
      Future<BossSessionResult<WorkLogUpdateResult>> updateRecord() {
        return BossSessionRunner.run<WorkLogUpdateResult>((controller) {
          return WorkLogSubmitService(controller).updateSubmittedLog(
            record: record,
            title: edited.title,
            content: edited.content,
            actWork: edited.actWork,
          );
        });
      }

      var updated = await updateRecord();
      if (!mounted) return;
      if (updated.status == BossSessionStatus.noSession) {
        if (!await _promptBossLogin() || !mounted) return;
        updated = await updateRecord();
        if (!mounted) return;
      }
      final result = updated.value;
      if (!updated.isOk || result == null) {
        _showMessage('网络通信不稳定，修改结果无法确认，请勿立即重试');
        return;
      }

      switch (result.status) {
        case WorkLogUpdateStatus.updated:
          final updatedData = WorkLogEditScript.buildUpdatedData(
            record: record,
            title: edited.title,
            content: edited.content,
            actWork: edited.actWork,
          );
          setState(() {
            _submittedRecord = BossWorkLogRecord(
              objectId: objectId,
              rawData: updatedData,
            );
          });
          _weekStripKey.currentState?.refresh();
          _showMessage('修改成功，已重新读取原日志确认');
          return;
        case WorkLogUpdateStatus.deferred:
          _showMessage(result.message ?? '网络通信不稳定，本次已暂缓修改');
          return;
        case WorkLogUpdateStatus.failed:
          _showMessage('修改失败：${result.message ?? 'BOSS 未保存修改'}');
          return;
      }
    } finally {
      _editingSubmitted = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _runHeadlessSubmit(
    WorkLogEntry entry,
    WorkLogDraft draft, {
    bool allowLogin = true,
  }) async {
    _showMessage('正在后台连接 BOSS…');

    final prepared = await BossSessionRunner.run<_SubmitPreparation>((
      controller,
    ) async {
      final service = WorkLogSubmitService(controller);
      final existingHours = await service.queryExistingHours(draft.date);
      if (existingHours == null || existingHours > 0) {
        return _SubmitPreparation.preflightBlocked(existingHours);
      }

      final resolution = await service.resolveConstants(entry.projectName);
      // 项目清单扫到了就还有救——让用户自己挑一个即可，不该在这里就判死刑。
      // 只有连清单带配置都拿不到，才轮到诊断。
      if (!resolution.hasConstants && !resolution.needsProjectPick) {
        final (conclusion, report) = await service.collectDiagnostics(
          entry.projectName,
        );
        return _SubmitPreparation.failed(
          resolution.reason ?? conclusion,
          report,
        );
      }
      return _SubmitPreparation(
        constants: resolution.constants,
        existingHours: existingHours,
        needsProjectPick: resolution.needsProjectPick,
        projects: resolution.projects,
        auditors: resolution.auditors,
      );
    });

    if (!mounted) return;

    if (prepared.status == BossSessionStatus.noSession) {
      if (allowLogin && await _promptBossLogin() && mounted) {
        await _runHeadlessSubmit(entry, draft, allowLogin: false);
      } else if (!allowLogin) {
        _showMessage('已登录，但后台会话尚未就绪，请稍后再试');
      }
      return;
    }
    final prep = prepared.value;
    if (!prepared.isOk || prep == null) {
      _showMessage('连接 BOSS 失败，请稍后重试');
      return;
    }
    if (prep.preflightBlocked) {
      final existingHours = prep.existingHours;
      if (existingHours != null && existingHours > 0) {
        _showMessage(
          '${draft.date} 已在 BOSS 填报 '
          '${WorkTimeCalculator.formatHours(existingHours)} 小时，本次未重复提交',
        );
      } else {
        _showMessage('网络通信不稳定，未能确认 ${draft.date} 是否已提交，本次已暂缓');
      }
      return;
    }
    if (prep.constants == null && !prep.needsProjectPick) {
      await Clipboard.setData(ClipboardData(text: prep.diagnostics ?? ''));
      if (!mounted) return;
      _showMessage('${prep.conclusion ?? '未取到项目信息'}（诊断已复制到剪贴板）');
      return;
    }

    // CSV 的项目名在 BOSS 里没有同名项目：先让用户从全量清单里挑出正确的那个。
    // 替他猜等于把「静默绑错项目」换身衣服重来一遍，且更难被发现。
    var constants = prep.constants ?? const <String, String>{};
    if (prep.needsProjectPick) {
      final picked = await WorkLogProjectPickerDialog.pickAndBind(
        context: context,
        csvProjectName: entry.projectName,
        constants: constants,
        projects: prep.projects,
      );
      if (!mounted) return;
      if (picked == null) {
        _showMessage(
          prep.projects.isEmpty
              ? '已取消提交。请在「提交配置」里手工填写正确的项目 ID'
              : '已取消提交。若清单里没有正确的项目，可在「提交配置」里手工填 ID',
        );
        return;
      }
      constants = picked;
    }

    // 审核人是和项目并列的另一件事，不是它的附属。缺了就单独补，
    // 不该因为审核人没扫到就把选项目那条路一起封死（那正是上一版的错）。
    if ((constants['auditor'] ?? '').isEmpty) {
      final picked = await WorkLogAuditorPickerDialog.pick(
        context: context,
        constants: constants,
        auditors: prep.auditors,
      );
      if (!mounted) return;
      if (picked == null) {
        _showMessage(
          prep.auditors.isEmpty
              ? '没扫到审核人。去「我的工作日志」点开一个已填过的日期，或在「提交配置」里手工填'
              : '已取消提交。审核人必须选一个，否则日志会发给错误的审批人',
        );
        return;
      }
      constants = await WorkLogSubmitService.bindConstants(
        picked,
        entry.projectName,
      );
      if (!mounted) return;
    }

    // 面向公司真实系统，绝不静默提交；工时也在这里允许调整。
    // 用户在确认框里点「改选」时回到对应的选择框，改完再回来重新核对一遍——
    // 改了项目或审核人还接着用上一屏的核对结果，等于没核对。
    String actWork;
    while (true) {
      final outcome = await WorkLogConfirmDialog.show(
        context: context,
        date: draft.date,
        entry: entry,
        hours: draft.hours,
        existingHours: prep.existingHours,
        constants: constants,
        // **永远给「改选」**。以前是「扫到候选才给」，结果清单一空，用户就被
        // 卡在一个没有任何出路的确认框上（他的原话：不知道该怎么处理了）。
        // 候选空不是「不能改」，只是「这一趟没扫到」——点了现场重扫即可。
        canChangeProject: true,
        canChangeAuditor: true,
      );
      if (outcome == null || !mounted) return;

      if (outcome.changeProject) {
        final projects = await _ensureProjects(prep);
        if (!mounted) return;
        final picked = await WorkLogProjectPickerDialog.pickAndBind(
          context: context,
          csvProjectName: entry.projectName,
          constants: constants,
          projects: projects,
          purpose: ProjectPickPurpose.change,
        );
        if (!mounted) return;
        if (picked != null) constants = picked;
        continue;
      }

      if (outcome.changeAuditor) {
        final auditors = await _ensureAuditors(prep);
        if (!mounted) return;
        final picked = await WorkLogAuditorPickerDialog.pick(
          context: context,
          constants: constants,
          auditors: auditors,
        );
        if (!mounted) return;
        if (picked != null) {
          constants = await WorkLogSubmitService.bindConstants(
            picked,
            entry.projectName,
          );
          if (!mounted) return;
        }
        continue;
      }

      actWork = outcome.actWork!;
      break;
    }

    _showMessage('正在提交…');
    final result = await BossSessionRunner.run<WorkLogSubmitResult>((
      controller,
    ) async {
      return WorkLogSubmitService(
        controller,
      ).submit(entry: entry, actWork: actWork, constants: constants);
    });

    if (!mounted) return;
    final outcome = result.value;
    if (result.isOk && outcome != null) {
      switch (outcome.status) {
        case WorkLogSubmitStatus.submitted:
          _showMessage(outcome.message ?? '提交成功');
          await _reload();
          return;
        case WorkLogSubmitStatus.alreadySubmitted:
          final hours = outcome.existingHours;
          _showMessage(
            hours == null
                ? '${draft.date} 已有日志，本次未重复提交'
                : '${draft.date} 已在 BOSS 填报 '
                      '${WorkTimeCalculator.formatHours(hours)} 小时，本次未重复提交',
          );
          await _reload();
          return;
        case WorkLogSubmitStatus.deferred:
          _showMessage(outcome.message ?? '网络通信不稳定，本次已暂缓提交');
          return;
        case WorkLogSubmitStatus.failed:
          _showMessage('提交失败：${outcome.message ?? '未知错误'}');
          return;
      }
    }
    _showMessage('网络通信不稳定，本次已暂缓提交');
  }

  /// 拿项目清单：准备阶段已经扫到就直接用，扫空了就现场再扫一次（带重试）。
  ///
  /// 准备阶段为了不拖慢正常提交，已绑定时只扫一次不等待（`retries: 0`），
  /// 扫空是常事。但用户主动点「改选」时的诉求是明确的——**他就是要一份清单**，
  /// 这时候多等两秒远比给他一个空列表强。
  Future<List<BossProject>> _ensureProjects(_SubmitPreparation prep) async {
    if (prep.projects.isNotEmpty) return prep.projects;

    _showMessage('正在扫描 BOSS 项目清单…');
    final result = await BossSessionRunner.run<List<BossProject>>(
      (controller) => WorkLogSubmitService(controller).listProjects(),
    );
    return result.value ?? const [];
  }

  /// 拿审核人候选，理由同 [_ensureProjects]。
  Future<List<BossAuditor>> _ensureAuditors(_SubmitPreparation prep) async {
    if (prep.auditors.isNotEmpty) return prep.auditors;

    _showMessage('正在扫描审核人…');
    final result = await BossSessionRunner.run<List<BossAuditor>>(
      (controller) => WorkLogSubmitService(controller).lookupAuditors(),
    );
    return result.value ?? const [];
  }

  /// 后台会话拿不到登录态时，用原生面板完成一次隐藏登录。
  Future<bool> _promptBossLogin() =>
      BossLoginCoordinator.prompt(context: context, openWeb: _openReportSystem);

  Future<void> _loginBossFromConfig() async {
    final loggedIn = await BossLoginCoordinator.prompt(
      context: context,
      openWeb: _openReportSystem,
      successMessage: 'BOSS 登录成功，之后可直接提交日志',
    );
    if (loggedIn && mounted) unawaited(refreshBossHoursSilently());
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
                  WeekStrip(
                    key: _weekStripKey,
                    selectedDate: _selectedDate,
                    onDateSelected: _selectDate,
                    loadWeek: _repository.loadWeek,
                  ),
                  const SizedBox(height: 12),
                  _buildHoursCard(),
                  const SizedBox(height: 12),
                  _buildEntryCard(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
      bottomNavigationBar: _buildSubmitBar(),
    );
  }

  /// 底部常驻的提交栏。
  ///
  /// 提交是这个页面唯一的主操作，原先它是每日工时页 AppBar 上的一个小图标，
  /// 藏在最上面很容易被忽略。改为常驻底栏的整宽按钮，位置固定、面积足够大，
  /// 不像悬浮按钮那样会飘在内容上或被误当成装饰。
  ///
  /// 按钮上带日期：日期栏可以往前翻，不写清楚容易在翻到别的日期后
  /// 误以为提交的是今天。
  Widget _buildSubmitBar() {
    final canSubmit = _draft?.hasEntry == true;
    final date = _selectedDate;
    final canEdit = _submittedObjectId != null;
    final busy = _submitting || _editingSubmitted;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 不能提交时说明原因，而不是只把按钮置灰让人猜
            if (!canSubmit)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _totalCount == 0
                      ? '请先导入日志 CSV'
                      : 'CSV 中没有 ${DateHelper.formatDate(date)} 的记录',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
              ),
            Row(
              children: [
                // 次要操作：只想看看网页、不提交时用
                OutlinedButton(
                  onPressed: _openReportSystem,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(52, 52),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.open_in_browser),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy
                        ? null
                        : canEdit
                        ? _editSubmittedLog
                        : canSubmit
                        ? _submitLog
                        : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(canEdit ? Icons.edit_note : Icons.rocket_launch),
                    label: Text(
                      _submitting
                          ? '提交中…'
                          : _editingSubmitted
                          ? '保存修改中…'
                          : canEdit
                          ? '编辑 ${date.month}月${date.day}日 已提交日志'
                          : '提交 ${date.month}月${date.day}日 日志',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// BOSS 提交配置未就绪时的引导卡片。
  ///
  /// 刻意**不**把「手工填三个 ID」当主入口：用户没有义务知道
  /// `PROJECT_xxxxxxxx` 是什么，更没义务去哪里翻出来。正常打开一次日志系统，
  /// APP 会在后台从网页会话里自己学到。手工填写只作为学不到时的兜底。
  Widget _buildConfigPrompt() {
    // 与「每日工时」页的跨天打卡提示卡同一形态：
    // 浅色底 + 同色描边 + 同色图标，elevation 与其它卡片一致
    return Card(
      elevation: 2,
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
                Icon(
                  Icons.auto_fix_high,
                  size: 20,
                  color: AppColors.warningDark,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BOSS 提交配置未就绪',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warningDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '可直接在后台登录；首次提交时 App 会自动获取项目和审核人，'
                        '不需要先打开 BOSS 网页。',
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
                  onPressed: _loginBossFromConfig,
                  icon: const Icon(Icons.login, size: 16),
                  label: const Text('登录 BOSS', style: TextStyle(fontSize: 12)),
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

  /// 统一的卡片外壳：彩色图标 + 加粗标题 + 可选右侧操作 + 内容。
  ///
  /// 前两个页签的卡片都是「elevation 2 / 圆角 12 / 彩色图标配加粗标题」这套，
  /// 本页原先各写各的，三个页签风格对不上。收敛到同一个外壳，
  /// 以后再加卡片也不会又长出第四种样式。
  Widget _buildSectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildImportCard() {
    final hasData = _totalCount > 0;
    return _buildSectionCard(
      icon: hasData ? Icons.description : Icons.upload_file,
      iconColor: hasData ? Colors.teal[700]! : Colors.grey,
      title: hasData ? '已导入 $_totalCount 条日志' : '尚未导入日志 CSV',
      trailing: TextButton(onPressed: _importCsv, child: const Text('导入')),
      child: Text(
        hasData
            ? '${_sourceName ?? '未知文件'}'
                  '${_importedAt == null ? '' : ' · ${DateHelper.formatDate(_importedAt!)}'}'
            : '点右上角或此处的导入按钮选择 CSV 文件',
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
    );
  }

  /// 月度页统计芯片的同款样式，用于短标签。
  Widget _buildChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: color.withValues(alpha: 0.9),
        ),
      ),
    );
  }

  /// 工作时长卡片，数据来自打卡记录，与「每日工时」页同一口径、同一种呈现：
  /// 大号彩色数字加单位，下面跟打卡区间。
  Widget _buildHoursCard() {
    final hours = _draft?.hours;
    final hasHours = hours?.hasData == true;
    // 复用工时计算器的格式化规则（浮点截断两位，不四舍五入）。
    final display = hasHours
        ? WorkTimeCalculator.formatHours(hours!.hours!)
        : '--';
    final color = hasHours ? Colors.indigo[700]! : Colors.grey;

    return _buildSectionCard(
      icon: Icons.timer_outlined,
      iconColor: color,
      title: '工作时长',
      trailing: hasHours
          ? IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: '复制工作时长',
              visualDensity: VisualDensity.compact,
              onPressed: () => _copy('工作时长', display),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 大号数字容易在字体放大时溢出，整体缩放而不是裁切
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  display,
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.1,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  hasHours ? '小时' : '未获取到打卡',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: color.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          if (hasHours && (hours!.checkIn != null || hours.checkOut != null))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.login, size: 14, color: Colors.green[600]),
                  const SizedBox(width: 4),
                  Text(
                    hours.checkIn ?? '--:--',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.logout, size: 14, color: Colors.orange[600]),
                  const SizedBox(width: 4),
                  Text(
                    hours.checkOut ?? '--:--',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEntryCard() {
    final entry = _draft?.entry;
    final submitted = _submittedRecord;

    if (entry == null) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.event_busy, size: 40, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text(
                _totalCount == 0
                    ? '请先导入日志 CSV'
                    : 'CSV 中没有 ${_draft?.date ?? ''} 的记录',
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return _buildSectionCard(
      icon: _submittedObjectId == null ? Icons.notes : Icons.task_alt,
      iconColor: _submittedObjectId == null
          ? Colors.deepPurple[400]!
          : Colors.green[700]!,
      title: _submittedObjectId == null ? '日志内容' : '已提交日志',
      trailing: _submittedObjectId == null
          ? null
          : TextButton.icon(
              onPressed: _editingSubmitted || _submitting
                  ? null
                  : _editSubmittedLog,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('编辑'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildField('标题', submitted?.title ?? entry.title, emphasize: true),
          _buildField(
            '工作内容',
            submitted?.content ?? entry.content,
            multiline: true,
          ),
          _buildField(
            '项目名称',
            submitted?.projectName.isNotEmpty == true
                ? submitted!.projectName
                : entry.projectName,
          ),
          const SizedBox(height: 4),
          // 类型、阶段、活动都是短标签，做成芯片比三行「标签+值」清爽得多，
          // 也和月度页的统计芯片对上了
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (entry.workType.isNotEmpty)
                _buildChip(entry.workType, Colors.deepPurple[400]!),
              if (entry.stage.isNotEmpty)
                _buildChip(entry.stage, Colors.blue[700]!),
              if (entry.activity.isNotEmpty)
                _buildChip(entry.activity, Colors.teal[700]!),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    String label,
    String value, {
    bool multiline = false,
    bool emphasize = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
                const SizedBox(height: 3),
                Text(
                  value.isEmpty ? '-' : value,
                  style: TextStyle(
                    fontSize: emphasize ? 15 : 14,
                    height: 1.5,
                    fontWeight: emphasize ? FontWeight.bold : FontWeight.normal,
                    color: Colors.grey[850],
                  ),
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

/// 提交前的准备结果：要么拿到了配置和已填工时，要么带回诊断信息。
class _SubmitPreparation {
  const _SubmitPreparation({
    this.constants,
    this.existingHours,
    this.needsProjectPick = false,
    this.projects = const [],
    this.auditors = const [],
  }) : preflightBlocked = false,
       conclusion = null,
       diagnostics = null;

  const _SubmitPreparation.preflightBlocked(this.existingHours)
    : constants = null,
      preflightBlocked = true,
      needsProjectPick = false,
      projects = const [],
      auditors = const [],
      conclusion = null,
      diagnostics = null;

  const _SubmitPreparation.failed(this.conclusion, this.diagnostics)
    : constants = null,
      existingHours = null,
      preflightBlocked = false,
      needsProjectPick = false,
      projects = const [],
      auditors = const [];

  final Map<String, String>? constants;
  final double? existingHours;
  final bool preflightBlocked;
  final String? conclusion;
  final String? diagnostics;

  /// CSV 的项目名在 BOSS 里没有同名项目，提交前要先让用户从清单里挑一个。
  final bool needsProjectPick;

  /// 从 BOSS 爬到的全量项目清单；供选择框列出，也决定确认框给不给「改选」。
  final List<BossProject> projects;

  /// 扫到的审核人候选；同样既供选择框，也决定确认框给不给「改选」。
  final List<BossAuditor> auditors;
}
