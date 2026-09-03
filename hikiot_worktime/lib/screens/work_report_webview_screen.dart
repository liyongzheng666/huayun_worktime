import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/theme/theme.dart';
import '../services/storage_service.dart';
import '../services/work_log_submit_service.dart';
import '../services/work_log_repository.dart';
import '../utils/date_helper.dart';
import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_fill_script.dart';
import '../utils/work_log_project_list_lookup.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/work_log_submit_script.dart';
import '../utils/work_time_calculator.dart';
import '../utils/work_log_auditor_lookup.dart';
import '../widgets/work_log_auditor_picker_dialog.dart';
import '../widgets/work_log_project_picker_dialog.dart';
import '../widgets/work_log_confirm_dialog.dart';

/// 提交流程里可供用户改选的两类候选。
///
/// 打包成一个对象而不是返回一对列表：这两样都是「扫到就能改选、扫不到就没有」
/// 的同类东西，分开传下去只会让每个签名都多带一个参数。
class BossPickables {
  const BossPickables(this.projects, this.auditors);

  final List<BossProject> projects;
  final List<BossAuditor> auditors;
}

/// 日志系统的可选入口。
///
/// 之所以不写死单个地址：原始链接带的 `code=` 是企业微信 OAuth 授权码，
/// 一次性且约 5 分钟过期，写死必然失效。这里保留几个入口，
/// 由用户实际登录后确认哪条路径可用。
class WorkReportEntry {
  const WorkReportEntry(this.label, this.url);

  final String label;
  final String url;

  /// BOSS 系统（CSV 里的「BOSS工作类型」即出自此系统）。
  ///
  /// 用 https 而非 http：iOS 的 ATS 默认禁止明文流量，走 https 才不需要
  /// 在 Info.plist 里放宽安全策略。实测该域名 https 可用。
  static const String host = 'https://boss.hoteamsoft.com';

  static const List<WorkReportEntry> all = [
    WorkReportEntry('登录', host),
    WorkReportEntry('工作日志', '$host/EntWeChat/workReport/worklog_submit.html'),
    WorkReportEntry('汇报首页', '$host/EntWeChat/workReport/index.html'),
  ];
}

/// 日志汇报系统网页页
///
/// 只负责承载网页与会话，不掺入 CSV 或考勤逻辑。
class WorkReportWebViewScreen extends StatefulWidget {
  const WorkReportWebViewScreen({
    super.key,
    this.initialUrl,
    this.fillDate,
    this.autoSubmit = false,
    this.autoSyncBossMonth,
  });

  final String? initialUrl;

  /// 「填充」按钮要写入的日期，为空时取当天。
  final DateTime? fillDate;

  /// 进入后自动等待登录完成并发起提交，用于「一键提交今日日志」。
  final bool autoSubmit;

  /// 非空时：进入后自动等登录完成 → 同步该月的 BOSS 工时 → 自动返回。
  ///
  /// 供月度页的「全量更新工时」调用。BOSS 工时只能在网页会话里取
  /// （凭据在页面请求体内，不能落到 APP），所以必须借道这个页面，
  /// 但对用户而言应当是一次点击完成，不该让他自己去翻菜单。
  final DateTime? autoSyncBossMonth;

  @override
  State<WorkReportWebViewScreen> createState() =>
      _WorkReportWebViewScreenState();
}

class _WorkReportWebViewScreenState extends State<WorkReportWebViewScreen> {
  InAppWebViewController? _controller;
  double _progress = 0;

  /// 当前地址。登录后模块的真实路径只有登录态下才可见，
  /// 因此把它显示出来并支持复制，便于反馈给开发者补成快捷入口。
  String _currentUrl = '';

  /// 页面自身可能设置不利于内嵌显示的 viewport，这里统一为随设备宽度自适应。
  static const String _viewportScript = '''
    (function() {
      var CONTENT = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes';
      function applyViewport() {
        var viewport = document.querySelector('meta[name=viewport]');
        if (!viewport) {
          viewport = document.createElement('meta');
          viewport.setAttribute('name', 'viewport');
          (document.head || document.documentElement).appendChild(viewport);
        }
        viewport.setAttribute('content', CONTENT);
      }
      applyViewport();
      document.addEventListener('DOMContentLoaded', applyViewport);
    })();
  ''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志汇报系统'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => _controller?.reload(),
          ),
          IconButton(
            icon: const Icon(Icons.content_paste_go),
            tooltip: '粘贴链接打开',
            onPressed: _openFromClipboard,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '开发者工具',
            // 「同步本月 BOSS 工时」已并入月度页的「全量更新工时」，
            // 不在这里重复提供入口——同一件事两个地方触发，
            // 用户既记不住又容易只更新了一半。
            onSelected: (value) {
              switch (value) {
                case 'dom':
                  _exportPageStructure();
                case 'clearCapture':
                  _clearCapture();
                case 'exportCapture':
                  _exportCapture();
                case 'exportProjects':
                  _exportProjects();
                case 'exportServices':
                  _exportServices();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'dom', child: Text('导出页面结构')),
              PopupMenuItem(value: 'clearCapture', child: Text('① 清空抓包')),
              PopupMenuItem(value: 'exportCapture', child: Text('② 导出抓包')),
              PopupMenuItem(value: 'exportProjects', child: Text('导出项目候选')),
              PopupMenuItem(value: 'exportServices', child: Text('导出服务清单')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress),
          _buildEntryBar(),
          _buildUrlBar(),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(widget.initialUrl ?? WorkReportEntry.all.first.url),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportZoom: true,
                cacheEnabled: true,
                thirdPartyCookiesEnabled: true, // 仅 Android 生效
                // iOS 专属：使用共享 Cookie 存储，登录态才能跨页面和重启保留。
                sharedCookiesEnabled: true,
                useWideViewPort: true,
                loadWithOverviewMode: true,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  source: _viewportScript,
                ),
                // 必须早于页面脚本执行，否则钩不到页面已持有的
                // XMLHttpRequest / fetch 原始引用。
                // forMainFrameOnly 默认为 true，而 BOSS 的模块页跑在 iframe 里，
                // 不关掉的话 iframe 内的请求一条也抓不到。
                UserScript(
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: false,
                  source: WorkLogRequestCapture.buildHookScript(),
                ),
              ]),
              onWebViewCreated: (controller) => _controller = controller,
              onProgressChanged: (_, progress) {
                setState(() => _progress = progress / 100);
              },
              onLoadStop: (_, url) {
                setState(() => _currentUrl = url?.toString() ?? '');
                // 无论是否一键提交，都在后台静默学习提交配置——
                // 用户正常浏览的过程本身就是学习素材，不该让他去填内部 ID
                _startBackgroundLearning();
                if (widget.autoSubmit) _startAutoSubmit();
                if (widget.autoSyncBossMonth != null) _startAutoSyncBossHours();
              },
              // 单页应用内部跳转不触发 onLoadStop，需单独监听。
              onUpdateVisitedHistory: (_, url, _) {
                setState(() => _currentUrl = url?.toString() ?? '');
              },
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 表单已打开时只补填，不必再点一次「新增」
          FloatingActionButton.small(
            heroTag: 'fillOnly',
            tooltip: '仅填充当前表单',
            onPressed: () => _runFill(),
            child: const Icon(Icons.edit_note),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.small(
            heroTag: 'openAndFill',
            tooltip: '打开表单并填充（备用方式）',
            onPressed: _openFormAndFill,
            child: const Icon(Icons.bolt),
          ),
          const SizedBox(height: 10),
          // 报文提交是主推方式：不依赖 DOM，能提交下拉项的真实值
          FloatingActionButton.extended(
            heroTag: 'submitApi',
            onPressed: _submitViaApi,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('提交日志'),
          ),
        ],
      ),
    );
  }

  /// 顶部入口切换条。
  Widget _buildEntryBar() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final entry in WorkReportEntry.all) ...[
            OutlinedButton(
              onPressed: () => _controller?.loadUrl(
                urlRequest: URLRequest(url: WebUri(entry.url)),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(entry.label, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// 一键填报：点开「新增工作日志」表单 → 等待渲染 → 填充当日内容。
  ///
  /// 表单没有独立网址（导出显示 url 始终是首页），只能靠模拟点击工具栏按钮打开。
  /// 表单为异步渲染，因此填充采用轮询重试而非固定等待。
  Future<void> _openFormAndFill() async {
    final controller = _controller;
    if (controller == null) return;

    final opened = await controller.evaluateJavascript(
      source: WorkLogFillScript.buildOpenForm(),
    );

    var clicked = false;
    try {
      final decoded = jsonDecode(opened?.toString() ?? '{}');
      clicked = decoded is Map && decoded['clicked'] == true;
    } catch (_) {}

    if (!clicked) {
      _notify('没找到「新增工作日志」按钮，请确认已登录并停在日志列表页');
      return;
    }

    // 表单异步渲染，重试若干次直到字段出现。
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      final filled = await _runFill(silent: attempt < 5);
      if (filled) return;
    }
  }

  /// 把当日的 CSV 内容与打卡工时填入网页表单。
  ///
  /// 只填标题、工作内容、正常工时三项：下拉框与 autoCombox 是自研伪控件，
  /// 直接赋值只改显示不改内部状态，保存时会提交空值，交由用户手动选择更安全。
  /// 填充后不自动点击「保存」，必须由用户核对后提交。
  /// 执行一次填充。
  ///
  /// [silent] 为 true 时不弹提示，供「一键填报」轮询重试期间使用，
  /// 避免每次重试都打扰用户。
  /// 返回是否至少填成功一个字段。
  Future<bool> _runFill({bool silent = false}) async {
    final controller = _controller;
    if (controller == null) return false;

    final date = widget.fillDate ?? DateHelper.getWorkDate();
    final draft = await WorkLogRepository().loadDraft(date);
    final entry = draft.entry;

    if (entry == null) {
      if (!silent) _notify('CSV 中没有 ${draft.date} 的记录，请先导入或换个日期');
      return false;
    }

    final fields = <WorkLogFillField>[
      WorkLogFillField(label: '标题', value: entry.title),
      WorkLogFillField(label: '工作内容', value: entry.content),
      if (draft.hours.hasData)
        WorkLogFillField(
          label: '正常工时',
          value: WorkTimeCalculator.formatHours(draft.hours.hours!),
        ),
    ];

    try {
      final result = await controller.evaluateJavascript(
        source: WorkLogFillScript.build(fields),
      );
      if (!mounted) return false;

      final raw = result?.toString();
      final anyFilled = _countFilled(raw) > 0;
      if (!silent || anyFilled) _notify(_describeFillResult(raw));
      return anyFilled;
    } catch (e) {
      if (!silent) _notify('填充失败: $e');
      return false;
    }
  }

  int _countFilled(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map) return 0;
      return ((decoded['filled'] as List?) ?? const []).length;
    } catch (_) {
      return 0;
    }
  }

  /// 把脚本返回的 JSON 结果翻译成一句中文提示。
  String _describeFillResult(String? raw) {
    if (raw == null || raw.isEmpty) return '填充脚本没有返回结果';

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return '填充结果无法解析';

      List<String> read(String key) =>
          ((decoded[key] as List?) ?? const []).map((e) => '$e').toList();

      final filled = read('filled');
      final missing = read('missing');
      final skipped = read('skipped');

      final parts = <String>[];
      parts.add(filled.isEmpty ? '未填充任何字段' : '已填充：${filled.join('、')}');
      if (missing.isNotEmpty) parts.add('未找到：${missing.join('、')}');
      if (skipped.isNotEmpty) parts.add('跳过只读：${skipped.join('、')}');
      return parts.join('；');
    } catch (e) {
      return '填充结果解析失败';
    }
  }

  /// 自动提交是否已触发，避免页面多次 onLoadStop 时重复轮询。
  bool _autoSubmitStarted = false;

  /// 提交互斥锁。BOSS 不做幂等校验，重复提交会静默产生重复日志。
  bool _submitting = false;

  /// 一键提交：等登录完成（会话就绪）后自动发起提交。
  ///
  /// 不需要用户手动导航到填报页——提交走的是报文，与页面停在哪无关。
  Future<void> _startAutoSubmit() async {
    if (_autoSubmitStarted) return;
    _autoSubmitStarted = true;

    final controller = _controller;
    if (controller == null) return;

    // 轮询等待会话就绪。登录后首页会自动发若干带 para 的请求，
    // 但时机不定，因此给足重试次数而不是固定等待。
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!mounted) return;

      try {
        final probe = await controller.evaluateJavascript(
          source: WorkLogSubmitScript.buildSessionProbeScript(
            captureStoreName: WorkLogRequestCapture.storeName,
          ),
        );
        debugPrint('[日志提交] 会话探测 #$attempt = ${probe?.toString()}');
        final decoded = jsonDecode(probe?.toString() ?? '{}');
        if (decoded is Map && decoded['ready'] == true) {
          if (!mounted) return;
          await _submitViaApi();
          return;
        }
      } catch (_) {
        // 探测失败按未就绪处理，继续重试
      }

      await Future.delayed(const Duration(milliseconds: 700));
    }

    if (!mounted) return;
    _notify('等待登录超时。登录完成后可点右下角「提交日志」');
    // 允许用户登录后手动重试
    _autoSubmitStarted = false;
  }

  /// 直接以报文方式提交当日日志，不经过表单。
  ///
  /// 相比模拟填表，这条路不依赖 DOM 与自研控件，且能提交下拉项对应的
  /// 真实值（项目 ID、日志类型编码），是更可靠的方式。
  Future<void> _submitViaApi() async {
    final controller = _controller;
    if (controller == null) return;

    // 互斥：双击按钮、或自动提交与手动提交并发，都会往公司系统写重复记录。
    if (_submitting) {
      _notify('正在提交中，请稍候');
      return;
    }
    _submitting = true;

    try {
      await _runSubmit(controller);
    } finally {
      _submitting = false;
    }
  }

  Future<void> _runSubmit(InAppWebViewController controller) async {
    final date = widget.fillDate ?? DateHelper.getWorkDate();
    final draft = await WorkLogRepository().loadDraft(date);
    final entry = draft.entry;

    if (entry == null) {
      _notify('CSV 中没有 ${draft.date} 的记录');
      return;
    }
    // 没有打卡工时不再直接拦下：确认框里可以手填，
    // 出差、补录、打卡异常这些场景本来就该由用户自己定工时。

    final service = WorkLogSubmitService(controller);
    final existingHours = await service.queryExistingHours(draft.date);
    if (!mounted) return;
    if (existingHours == null) {
      _notify('网络通信不稳定，未能确认 ${draft.date} 是否已提交，本次已暂缓');
      return;
    }
    if (existingHours > 0) {
      _notify(
        '${draft.date} 已在 BOSS 填报 '
        '${WorkTimeCalculator.formatHours(existingHours)} 小时，本次未重复提交',
      );
      return;
    }

    final (resolved, pickables) = await _resolveBossConstants(
      service,
      entry.projectName,
    );
    if (resolved == null) return;
    var constants = resolved;

    if (!mounted) return;
    // 用户可在确认框里调整工时，因此提交的是它返回的值而非打卡原值；
    // 点「改选」时回到选择框，改完再回来重新核对一遍
    String actWork;
    while (true) {
      final outcome = await WorkLogConfirmDialog.show(
        context: context,
        date: draft.date,
        entry: entry,
        hours: draft.hours,
        existingHours: existingHours,
        constants: constants,
        // 永远给「改选」：候选空只是「这一趟没扫到」，不是「不能改」。
        // 藏起来的后果是用户被卡在一个没有出路的确认框上。
        canChangeProject: true,
        canChangeAuditor: true,
      );
      if (outcome == null || !mounted) return;

      if (outcome.changeProject) {
        var projects = pickables.projects;
        if (projects.isEmpty) {
          _notify('正在扫描 BOSS 项目清单…');
          projects = await service.listProjects();
          if (!mounted) return;
        }
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
        var auditors = pickables.auditors;
        if (auditors.isEmpty) {
          _notify('正在扫描审核人…');
          auditors = await service.lookupAuditors();
          if (!mounted) return;
        }
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

    final result = await service.submit(
      entry: entry,
      actWork: actWork,
      constants: constants,
    );
    if (!mounted) return;

    switch (result.status) {
      case WorkLogSubmitStatus.submitted:
        _notify(
          result.objectId == null
              ? (result.message ?? '提交成功')
              : '提交成功：${result.objectId}',
        );
        await controller.reload();
        return;
      case WorkLogSubmitStatus.alreadySubmitted:
        final hours = result.existingHours;
        _notify(
          hours == null
              ? '${draft.date} 已有日志，本次未重复提交'
              : '${draft.date} 已在 BOSS 填报 '
                    '${WorkTimeCalculator.formatHours(hours)} 小时，本次未重复提交',
        );
        await controller.reload();
        return;
      case WorkLogSubmitStatus.deferred:
        _notify(result.message ?? '网络通信不稳定，本次已暂缓提交');
        return;
      case WorkLogSubmitStatus.failed:
        _notify('提交失败：${result.message ?? '未知错误'}');
        return;
    }
  }

  /// 后台学习是否已启动，避免每次 onLoadStop 都开一轮轮询。
  bool _learningStarted = false;

  /// 后台静默学习 BOSS 提交配置。
  ///
  /// 这是为了消掉「必须先手工填三个内部 ID」这件反人类的事。用户没有义务
  /// 知道 `PROJECT_xxxxxxxx` 是什么、更没义务去哪里找它——他正常登录、
  /// 正常翻一次日志列表、正常填一次日志的过程本身就是学习素材，
  /// 这里只是在旁边看着，一旦抓包里出现项目信息就存下来。
  ///
  /// 学不到不打扰用户：提交时还会再试一次，仍失败才给诊断和手工配置入口。
  Future<void> _startBackgroundLearning() async {
    if (_learningStarted) return;
    _learningStarted = true;

    final projectName = await _preferredProjectName();

    // 项目对得上才算已配置：项目换了就得重新学，否则会用旧项目的 ID 提交。
    // 按项目名记住的绑定也算数，否则已经绑好的项目会被反复学、反复提示
    if (await WorkLogSubmitService.hasUsableConstantsFor(projectName)) return;

    // 轮询而非一次性扫描：用户何时登录、何时点开列表都不确定。
    // 2.5 秒一次、最多约 2 分钟，足够覆盖登录加浏览，也不会一直空转。
    for (var attempt = 0; attempt < 48; attempt++) {
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return;

      // 提交也在发同步请求，避开以免互相拖慢
      if (_submitting) continue;

      final controller = _controller;
      if (controller == null) continue;

      final learned = await WorkLogSubmitService(
        controller,
      ).learnConstants(projectName);
      if (learned != null) {
        if (!mounted) return;
        _notify('已自动获取 BOSS 提交配置，之后可直接一键提交');
        return;
      }
    }

    // 轮询到头仍没学到。这不是异常，只是用户这段时间没做过带完整信息的操作，
    // 明确告诉他该做什么，比默默失败强。
    if (!mounted) return;
    final done = await WorkLogSubmitService.hasUsableConstantsFor(projectName);
    if (!mounted || done) return;
    // 现在提交时会先爬全量项目清单让用户自己选，历史日志只是其中一条来源，
    // 所以这里不能再说得像「不去点一下就没救了」
    _notify('尚未自动获取到配置。直接提交也行，届时可从 BOSS 的项目清单里选');
  }

  /// 取提交所需的业务标识；拿不到时给出诊断并复制到剪贴板。
  ///
  /// 业务编排在 [WorkLogSubmitService]，这里只负责提示与剪贴板这类界面动作，
  /// 保证后台提交与网页内提交走的是同一套逻辑。
  ///
  /// 一并把爬到的项目清单带回去：提交确认框要靠它决定给不给「改选」入口。
  Future<(Map<String, String>?, BossPickables)> _resolveBossConstants(
    WorkLogSubmitService service,
    String projectName,
  ) async {
    final saved = await StorageService().loadBossConstants();

    final changedProject =
        saved['projectId']?.isNotEmpty == true &&
        (saved['projectName'] ?? '').isNotEmpty;

    // 走服务里的统一解析，绑定判定与后台提交保持一致；
    // 两条路径各判各的，迟早会出现「网页里能提交、后台却要求重新确认」。
    final resolution = await service.resolveConstants(projectName);
    final pickables = BossPickables(resolution.projects, resolution.auditors);

    var constants = resolution.constants;

    if (resolution.needsProjectPick) {
      // 项目名在 BOSS 里没有同名的，先让用户从全量清单里挑——
      // 弹的是与后台提交同一个框，同一套落绑定的逻辑
      if (!mounted) return (null, pickables);
      final picked = await WorkLogProjectPickerDialog.pickAndBind(
        context: context,
        csvProjectName: projectName,
        constants: constants ?? const {},
        projects: pickables.projects,
      );
      if (!mounted) return (null, pickables);
      if (picked == null) {
        _notify('已取消。若清单里没有正确的项目，可在工作日志页的「提交配置」里手工填 ID');
        return (null, pickables);
      }
      constants = picked;
    }

    if (constants != null) {
      // 审核人和项目是两件独立的事，缺了单独补，不封死另一条路
      if ((constants['auditor'] ?? '').isEmpty) {
        if (!mounted) return (null, pickables);
        final picked = await WorkLogAuditorPickerDialog.pick(
          context: context,
          constants: constants,
          auditors: pickables.auditors,
        );
        if (!mounted) return (null, pickables);
        if (picked == null) {
          _notify(
            pickables.auditors.isEmpty
                ? '没扫到审核人。到「我的工作日志」点开一个已填过的日期，再回来提交'
                : '已取消。审核人必须选一个，否则日志会发给错误的审批人',
          );
          return (null, pickables);
        }
        constants = await WorkLogSubmitService.bindConstants(
          picked,
          projectName,
        );
      }
      return (constants, pickables);
    }

    // 项目变了却拿不到新配置时，宁可停下也不能拿旧项目的 ID 提交
    if (changedProject) {
      if (!mounted) return (null, pickables);
      _notify(
        resolution.reason ??
            '项目已变为「$projectName」，但还没拿到它的提交配置。'
                '请在网页上为该项目填报一次日志',
      );
      return (null, pickables);
    }

    // Release 构建不开 Dart VM 服务，flutter logs 抓不到 debugPrint，
    // 因此失败时把诊断信息复制到剪贴板，便于直接反馈。
    final (conclusion, report) = await service.collectDiagnostics(projectName);
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return (null, pickables);
    _notify(
      resolution.reason ??
          (conclusion == null || conclusion.isEmpty
              ? '未取到项目信息。请到「我的工作日志」点开任意一个已填过的日期（诊断已复制到剪贴板）'
              : '$conclusion（诊断已复制到剪贴板）'),
    );
    return (null, pickables);
  }

  /// 当日 CSV 条目里的项目名，用于在多项目时挑对那一个；取不到返回空串。
  ///
  /// 只读 CSV 条目而不用 loadDraft：后者会顺带拉一次考勤工时，
  /// 而这里只要项目名，没必要为此发一次网络请求。
  Future<String> _preferredProjectName() async {
    final date = widget.fillDate ?? DateHelper.getWorkDate();
    final entry = await WorkLogRepository().loadEntry(
      DateHelper.formatDate(date),
    );
    return entry?.projectName ?? '';
  }

  /// 自动同步是否已触发，避免多次 onLoadStop 重复开轮询。
  bool _autoSyncStarted = false;

  /// 「全量更新工时」带过来的自动同步：等登录完成 → 同步该月 → 自动返回。
  ///
  /// 不设超时上限后自动退出：用户可能正停在登录页慢慢输密码，
  /// 这时候把页面关掉等于白跑一趟。轮询会一直等到会话就绪，
  /// 用户不想等随时可以自己返回。
  Future<void> _startAutoSyncBossHours() async {
    if (_autoSyncStarted) return;
    _autoSyncStarted = true;

    final month = widget.autoSyncBossMonth;
    if (month == null) return;

    for (var attempt = 0; ; attempt++) {
      if (!mounted) return;

      final controller = _controller;
      if (controller != null) {
        try {
          final probe = await controller.evaluateJavascript(
            source: WorkLogSubmitScript.buildSessionProbeScript(
              captureStoreName: WorkLogRequestCapture.storeName,
            ),
          );
          final decoded = jsonDecode(probe?.toString() ?? '{}');
          if (decoded is Map && decoded['ready'] == true) break;
        } catch (_) {
          // 探测失败按未就绪处理，继续等
        }
      }

      // 等久了给一次提示，免得用户以为卡住了
      if (attempt == 12 && mounted) {
        _notify('等待登录完成后会自动同步 BOSS 工时');
      }
      await Future.delayed(const Duration(milliseconds: 700));
    }

    if (!mounted) return;
    final ok = await _syncBossHours(month: month);

    // 同步完自动退回月度页，用户不必再手动返回
    if (!mounted) return;
    Navigator.of(context).pop(ok);
  }

  /// 同步指定月份的 BOSS 已填工时到本地，供月历页展示。
  ///
  /// 逐日请求（一个月约 30 次），因此执行期间给出等待提示。
  /// 返回是否真的取到了数据。
  Future<bool> _syncBossHours({DateTime? month}) async {
    final controller = _controller;
    if (controller == null) return false;

    final date = month ?? widget.fillDate ?? DateHelper.getWorkDate();
    final monthKey = DateHelper.formatMonth(date);
    _notify('正在同步 $monthKey 的 BOSS 工时，约需数十秒…');

    try {
      final result = await controller.evaluateJavascript(
        source: WorkLogBossHours.buildFetchMonthScript(
          year: date.year,
          month: date.month,
          captureStoreName: WorkLogRequestCapture.storeName,
        ),
      );

      final hours = WorkLogBossHours.parseResult(result?.toString());
      if (hours.isEmpty) {
        if (!mounted) return false;
        _notify('未取到任何 BOSS 工时，请确认已登录并在页面上操作过一次');
        return false;
      }

      await StorageService().saveBossHours(monthKey, hours);
      if (!mounted) return false;
      _notify('已同步 $monthKey：${hours.length} 天有填报记录');
      return true;
    } catch (e) {
      _notify('同步失败：$e');
      return false;
    }
  }

  /// 清空已抓到的请求。
  ///
  /// 配合「清空 → 只点一次保存 → 导出」使用，可把目标报文从
  /// 页面的轮询噪声里精确摘出来。
  Future<void> _clearCapture() async {
    await _controller?.evaluateJavascript(
      source: WorkLogRequestCapture.buildClearScript(),
    );
    // 项目下拉是打开表单时一次性加载、之后本地过滤的，打字不再发请求。
    // 清空会把那份列表连同一切响应一起删掉，而它删完之后不会自己回来——
    // 必须重新打开表单。不说清楚的话，「清空→操作→导出」看起来天经地义，
    // 实际拿到的永远是空报告（本项目已因此浪费过一轮排查）。
    _notify('已清空抓包。项目列表等已加载的数据也一并清掉了，需重新打开表单才会回来');
  }

  /// 导出抓到的写请求（POST/PUT 等），保存动作必在其中。
  Future<void> _exportCapture() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final result = await controller.evaluateJavascript(
        source: WorkLogRequestCapture.buildExportScript(),
      );
      final text = result?.toString() ?? '';
      if (!mounted) return;

      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _notify('已复制抓包结果（${text.length} 字符）');
    } catch (e) {
      _notify('导出抓包失败: $e');
    }
  }

  /// 导出扫到的项目候选，用于核对「我的项目」网格有没有被抓到。
  ///
  /// 与「导出抓包」不同，**这份输出可以安全外发**：只含项目名与
  /// `PROJECT_` 标识，不含任何凭据。原始抓包里每个请求体都带明文
  /// `Password`（见 docs/踩坑记录.md 3.12），那份绝不能外发。
  Future<void> _exportProjects() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final projects = await WorkLogSubmitService(controller).listProjects();
      if (!mounted) return;

      if (projects.isEmpty) {
        // 光说「没扫到」等于把排查甩回给用户。抓包为空、没登录、
        // 形状不认识是三种完全不同的原因，诊断脚本本来就分得清，
        // 直接把结论讲出来，省掉一轮「导出报告→找人看」
        final (conclusion, _) = await WorkLogSubmitService(
          controller,
        ).collectDiagnostics(await _preferredProjectName());
        if (!mounted) return;
        _notify(
          conclusion == null || conclusion.isEmpty
              ? '没扫到项目。请在网页上打开一次首页或「我的工作日志」'
              : '没扫到项目：$conclusion',
        );
        return;
      }

      final text = projects.map((p) => '${p.name}\t${p.id}').join('\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _notify('已复制 ${projects.length} 个项目候选（不含凭据）');
    } catch (e) {
      _notify('导出项目候选失败: $e');
    }
  }

  /// 导出页面调过哪些服务，用于定位「按关键字查项目」这类接口。
  ///
  /// 踩坑记录 3.15：**找服务名比扫响应内容可靠得多**。BOSS 所有业务共用
  /// 同一个 DataService 入口，靠 `para.ServiceUri` 区分；知道服务名和它吃
  /// 哪些参数，就能照着重放，不必再靠猜响应形状碰运气。
  ///
  /// 输出已由诊断脚本就地打码（`Password` / `LoginID` 一律替换为 `***`，
  /// 服务参数只取键名不取值），**可以安全外发**。
  Future<void> _exportServices() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final service = WorkLogSubmitService(controller);
      final (conclusion, report) = await service.collectDiagnostics(
        await _preferredProjectName(),
      );
      await Clipboard.setData(ClipboardData(text: report));
      if (!mounted) return;
      // 结论比字符数有用得多：抓包为空时，报告里全是零，
      // 而「未捕获到会话」这一句才是用户真正要看到的
      _notify(
        conclusion == null || conclusion.isEmpty
            ? '已复制服务清单（凭据已打码）'
            : '已复制服务清单。$conclusion',
      );
    } catch (e) {
      _notify('导出服务清单失败: $e');
    }
  }

  /// 从剪贴板读取链接并加载。
  ///
  /// 企业微信打开汇报系统时，URL 里带的是刚生成的 OAuth `code`（一次性、
  /// 约 5 分钟过期）。我们自己的 App 无法生成该 code，但用户可以在企业微信里
  /// 复制链接，趁未过期粘进来，WebView 即可拿到有效会话。
  Future<void> _openFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';

    if (text.isEmpty) {
      _notify('剪贴板是空的。请先在企业微信里复制汇报系统的链接');
      return;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || !uri.host.contains('hoteamsoft')) {
      _notify('剪贴板里不是汇报系统的链接');
      return;
    }

    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(text)));

    final hasCode = uri.queryParameters.containsKey('code');
    _notify(hasCode ? '已用带 code 的链接打开' : '已打开链接（未携带 code，可能需要重新授权）');
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 当前地址栏，支持一键复制。
  Widget _buildUrlBar() {
    if (_currentUrl.isEmpty) return const SizedBox.shrink();

    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _currentUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.link, size: 18),
            tooltip: '复制当前地址',
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _currentUrl));
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制当前地址')));
            },
          ),
        ],
      ),
    );
  }

  /// 导出当前页面 JS 渲染后的表单结构，供后续实现自动填充。
  ///
  /// 表单由脚本动态生成，静态 HTML 里看不到，只能在真机登录后现场抓取。
  Future<void> _exportPageStructure() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final result = await controller.evaluateJavascript(
        source: '''
          (function() {
            // 页面未使用标准 <label for>，只能从控件周围的可见文字反推标签。
            function nearbyLabel(el) {
              // 1) 标准 label
              if (el.labels && el.labels[0]) {
                var t = el.labels[0].innerText.trim();
                if (t) return t;
              }
              // 2) 表格布局：当前单元格的前一个单元格
              var cell = el.closest('td, th');
              if (cell && cell.previousElementSibling) {
                var t2 = (cell.previousElementSibling.innerText || '').trim();
                if (t2 && t2.length < 30) return t2;
              }
              // 3) 向上找最多 4 层，取容器内不属于任何表单控件的文字
              var node = el.parentElement;
              for (var depth = 0; node && depth < 4; depth++, node = node.parentElement) {
                var clone = node.cloneNode(true);
                var controls = clone.querySelectorAll('input, select, textarea, button');
                for (var i = 0; i < controls.length; i++) {
                  controls[i].parentNode && controls[i].parentNode.removeChild(controls[i]);
                }
                var text = (clone.innerText || '').replace(/\\s+/g, ' ').trim();
                if (text && text.length > 0 && text.length < 30) return text;
              }
              return null;
            }

            function isVisible(el) {
              var r = el.getBoundingClientRect();
              return r.width > 0 && r.height > 0;
            }

            function describe(el, index) {
              return {
                i: index,
                tag: el.tagName,
                type: el.getAttribute('type'),
                id: el.id || null,
                name: el.getAttribute('name'),
                cls: el.className || null,
                placeholder: el.getAttribute('placeholder'),
                labelGuess: nearbyLabel(el),
                visible: isVisible(el),
                readOnly: el.readOnly || el.className.indexOf('readonly') >= 0,
                value: (el.value || '').substring(0, 60),
                options: el.tagName === 'SELECT'
                  ? Array.prototype.slice.call(el.options).map(function(o) {
                      return { text: o.text, value: o.value };
                    })
                  : undefined
              };
            }

            var nodes = document.querySelectorAll('input, select, textarea, button');
            var fields = [];
            for (var i = 0; i < nodes.length; i++) {
              // 隐藏字段（如 __VIEWSTATE）对填表无用，直接排除以缩短输出
              if (nodes[i].getAttribute('type') === 'hidden') continue;
              fields.push(describe(nodes[i], i));
            }

            return JSON.stringify({
              url: location.href,
              title: document.title,
              fieldCount: fields.length,
              fields: fields
            }, null, 2);
          })();
        ''',
      );

      final text = result?.toString() ?? '';
      if (!mounted) return;

      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制页面结构（${text.length} 字符），粘贴给开发者即可'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }
}
