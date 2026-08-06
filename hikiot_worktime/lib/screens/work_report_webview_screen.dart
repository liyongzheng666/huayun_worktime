import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/theme/theme.dart';
import '../services/storage_service.dart';
import '../services/work_log_repository.dart';
import '../utils/date_helper.dart';
import '../utils/work_log_boss_hours.dart';
import '../utils/work_log_constants_scanner.dart';
import '../utils/work_log_csv_parser.dart';
import '../utils/work_log_diagnostics_script.dart';
import '../utils/work_log_fill_script.dart';
import '../utils/work_log_history_lookup.dart';
import '../utils/work_log_request_capture.dart';
import '../utils/work_log_submit_script.dart';
import '../utils/work_time_calculator.dart';

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
  });

  final String? initialUrl;

  /// 「填充」按钮要写入的日期，为空时取当天。
  final DateTime? fillDate;

  /// 进入后自动等待登录完成并发起提交，用于「一键提交今日日志」。
  final bool autoSubmit;

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
            onSelected: (value) {
              switch (value) {
                case 'syncHours':
                  _syncBossHours();
                case 'dom':
                  _exportPageStructure();
                case 'clearCapture':
                  _clearCapture();
                case 'exportCapture':
                  _exportCapture();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'syncHours', child: Text('同步本月 BOSS 工时')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'dom', child: Text('导出页面结构')),
              PopupMenuItem(value: 'clearCapture', child: Text('① 清空抓包')),
              PopupMenuItem(value: 'exportCapture', child: Text('② 导出抓包')),
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
                url: WebUri(
                  widget.initialUrl ?? WorkReportEntry.all.first.url,
                ),
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

    final constants = await _resolveBossConstants(
      controller,
      entry.projectName,
    );
    if (constants == null) return;

    // BOSS 允许同一天填多条，重复提交不报错而是静默产生重复记录，
    // 因此提交前先查当天是否已有填报。
    final existingHours = await _queryExistingHours(controller, draft.date);

    if (!mounted) return;
    // 用户可在确认框里调整工时，因此提交的是它返回的值而非打卡原值
    final actWork = await _confirmSubmit(
      draft.date,
      entry,
      draft.hours,
      existingHours,
      constants,
    );
    if (actWork == null) return;

    try {
      final workLogData = WorkLogSubmitScript.buildWorkLogData(
        entry: entry,
        actWork: actWork,
        projectId: constants['projectId']!,
        projectCode: constants['projectCode'] ?? '',
        auditor: constants['auditor'] ?? '',
      );

      // 联合调试用：SnackBar 一闪而过，原始返回值才是能定位问题的东西
      debugPrint('[日志提交] payload=${jsonEncode(workLogData)}');

      final result = await controller.evaluateJavascript(
        source: WorkLogSubmitScript.build(
          workLogData: workLogData,
          captureStoreName: WorkLogRequestCapture.storeName,
        ),
      );
      debugPrint('[日志提交] 返回=${result?.toString()}');

      if (!mounted) return;
      final decoded = jsonDecode(result?.toString() ?? '{}');
      if (decoded is Map && decoded['ok'] == true) {
        _notify('提交成功：${decoded['objectId']}');
        await controller.reload();
      } else {
        _notify(
          '提交失败：${decoded is Map ? (decoded['message'] ?? decoded['reason']) : '未知错误'}',
        );
      }
    } on ArgumentError catch (e) {
      _notify('${e.message}');
    } catch (e) {
      _notify('提交出错：$e');
    }
  }

  /// 查询指定日期在 BOSS 已填报的工时，取不到返回 null（未知，不等于 0）。
  Future<double?> _queryExistingHours(
    InAppWebViewController controller,
    String dateStr,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(
        source: WorkLogBossHours.buildFetchSingleDayScript(
          dateStr: dateStr,
          captureStoreName: WorkLogRequestCapture.storeName,
        ),
      );
      return WorkLogBossHours.parseSingleDay(raw?.toString());
    } catch (e) {
      return null;
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

    final saved = await StorageService().loadBossConstants();
    // 项目对得上才算已配置：项目换了就得重新学，否则会用旧项目的 ID 提交
    if (_constantsUsableFor(saved, projectName)) return;

    // 轮询而非一次性扫描：用户何时登录、何时点开列表都不确定。
    // 2.5 秒一次、最多约 2 分钟，足够覆盖登录加浏览，也不会一直空转。
    for (var attempt = 0; attempt < 48; attempt++) {
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return;

      // 提交也在发同步请求，避开以免互相拖慢
      if (_submitting) continue;

      final controller = _controller;
      if (controller == null) continue;

      final learned = await _learnConstants(controller, projectName);
      if (learned != null) {
        if (!mounted) return;
        _notify('已自动获取 BOSS 提交配置，之后可直接一键提交');
        return;
      }
    }

    // 轮询到头仍没学到。这不是异常，只是用户这段时间没做过带完整信息的操作，
    // 明确告诉他该做什么，比默默失败强。
    if (!mounted) return;
    final still = await StorageService().loadBossConstants();
    if (!mounted || _constantsUsableFor(still, projectName)) return;
    _notify('尚未获取到配置。到「我的工作日志」点开任意一个已填过的日期即可');
  }

  /// 扫一次抓包，尝试学到提交配置；成功则落盘并返回。
  ///
  /// 三种来源按可靠度依次尝试：
  /// 1. 历史日志网格（`GetHisWorkLogList`）——按行解 JSON，三个值同源且能
  ///    挑出与当天项目一致的那一行，还能拿到审核人姓名供用户核对。最优。
  /// 2. 保存报文（用户刚在网页上填过一条）——语义精确，但要求用户先填过。
  /// 3. 正则扫描其余响应——兜底。
  Future<Map<String, String>?> _learnConstants(
    InAppWebViewController controller,
    String projectName,
  ) async {
    final fromHistory = _parseConstants(
      await _runScriptRaw(
        controller,
        WorkLogHistoryLookup.build(
          captureStoreName: WorkLogRequestCapture.storeName,
          preferredProjectName: projectName,
        ),
      ),
    );
    if (fromHistory != null) {
      await StorageService().saveBossConstants(fromHistory);
      return fromHistory;
    }

    final fromSave = _parseConstants(
      await _runScriptRaw(
        controller,
        WorkLogSubmitScript.buildExtractConstantsScript(
          captureStoreName: WorkLogRequestCapture.storeName,
        ),
      ),
    );
    if (fromSave != null) {
      await StorageService().saveBossConstants(fromSave);
      return fromSave;
    }

    // 不自己构造列表查询：BOSS 的列表是有状态视图，必须先由 GetTitle 在
    // 服务端建立上下文，单独调 GetDataGridList 只会返回空行（实测 200 且
    // Rows 为空）。改为收割页面自己查出来的数据，稳健得多。
    final scanned = _parseConstants(
      await _runScriptRaw(
        controller,
        WorkLogConstantsScanner.build(
          captureStoreName: WorkLogRequestCapture.storeName,
          preferredProjectName: projectName,
        ),
      ),
    );
    if (scanned != null) {
      await StorageService().saveBossConstants(scanned);
      return scanned;
    }

    return null;
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

  /// 已保存的配置是否可用于 [projectName] 这个项目。
  ///
  /// 用户的项目和审核人会换，一次学会就永久沿用是错的：换项目之后继续用
  /// 旧的 PROJECTID，会把新项目的日志记到旧项目名下，而且不会报错。
  ///
  /// 没记项目名的（手工填写的旧数据）无从核对，按可用处理，
  /// 否则会把用户自己填的值判死。
  static bool _constantsUsableFor(
    Map<String, String> saved,
    String projectName,
  ) {
    if (saved['projectId']?.isNotEmpty != true) return false;
    final savedName = saved['projectName'] ?? '';
    if (savedName.isEmpty || projectName.isEmpty) return true;
    return savedName == projectName;
  }

  /// 取提交所需的固定业务标识。
  ///
  /// 顺序：本地已保存且项目对得上 → 立刻再扫一次抓包。
  /// 都取不到才提示用户，并把诊断复制到剪贴板。
  ///
  /// 早期版本还会模拟点击菜单去「催」页面加载列表，已删除：那条路依赖
  /// 不透明的 SPA 菜单结构，是实测最不可靠的一条。
  Future<Map<String, String>?> _resolveBossConstants(
    InAppWebViewController controller,
    String projectName,
  ) async {
    final saved = await StorageService().loadBossConstants();
    if (_constantsUsableFor(saved, projectName)) return saved;

    final changedProject =
        saved['projectId']?.isNotEmpty == true &&
        (saved['projectName'] ?? '').isNotEmpty;

    final learned = await _learnConstants(controller, projectName);
    if (learned != null) return learned;

    // 项目变了却学不到新配置时，宁可停下也不能拿旧项目的 ID 提交
    if (changedProject) {
      if (!mounted) return null;
      _notify(
        '项目已变为「$projectName」，但还没拿到它的提交配置。'
        '请在网页上为该项目填报一次日志',
      );
      return null;
    }

    // Release 构建不开 Dart VM 服务，flutter logs 抓不到 debugPrint，
    // 因此失败时把诊断信息复制到剪贴板，便于直接反馈。
    await _copyDiagnostics(controller, projectName);
    return null;
  }

  /// 学不到配置时收集诊断信息并复制到剪贴板。
  Future<void> _copyDiagnostics(
    InAppWebViewController controller,
    String projectName,
  ) async {
    final probe = await _runScriptRaw(
      controller,
      WorkLogDiagnosticsScript.build(
        captureStoreName: WorkLogRequestCapture.storeName,
        preferredProjectName: projectName,
      ),
    );

    final decoded = _tryDecode(probe);
    final report = const JsonEncoder.withIndent('  ').convert({
      'stage': 'learnConstantsFailed',
      'preferredProjectName': projectName,
      'diagnostics': decoded,
    });

    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;

    // 优先显示脚本给出的人话结论，它比通用文案更能指向下一步该做什么
    final conclusion = (decoded is Map ? decoded['conclusion'] : null)
        ?.toString();
    _notify(
      conclusion == null || conclusion.isEmpty
          ? '未取到项目信息。请在网页上打开一次「我的工作日志」列表（诊断已复制到剪贴板）'
          : '$conclusion（诊断已复制到剪贴板）',
    );
  }

  static Object? _tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  Future<String?> _runScriptRaw(
    InAppWebViewController controller,
    String script,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(source: script);
      debugPrint('[日志提交] 脚本返回=${raw?.toString()}');
      return raw?.toString();
    } catch (e) {
      return '{"ok":false,"reason":"evalError","message":"$e"}';
    }
  }

  /// 解析脚本返回的常量。
  ///
  /// **自动获取时审核人必须一并拿到**：BOSS 首页的「我的项目」网格里有
  /// `PROJECT_xxx`，但完全没有工作日志的审核人；而抓包别处出现的 `USERINFO_`
  /// 往往是用户自己的 ID。只要项目 ID 就落盘的话，会拿一个错的（或空的）
  /// 审核人去提交，日志就发给了错误的审批人——这是公司真实系统上的后果，
  /// 宁可让用户手工填，也不能猜。
  ///
  /// 手工填写不走这里，用户自己决定要不要留空。
  Map<String, String>? _parseConstants(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) return null;

      final projectId = '${decoded['projectId'] ?? ''}';
      final auditor = '${decoded['auditor'] ?? ''}';
      if (projectId.isEmpty || auditor.isEmpty) return null;

      return {
        'projectId': projectId,
        'projectCode': '${decoded['projectCode'] ?? ''}',
        // BOSS 的保存报文里审核人带前导分号，而历史网格里不带，
        // 统一补齐为提交时的形态
        'auditor': auditor.startsWith(';') ? auditor : ';$auditor',
        // 记下这套值属于哪个项目，供后续核对——项目会换，
        // 换了以后旧值必须失效，不能拿旧项目的 ID 提交新项目的日志
        'projectName': '${decoded['projectName'] ?? ''}',
        // 审核人姓名只用于让用户在提交前肉眼核对，不参与报文
        'auditorName': '${decoded['auditorName'] ?? ''}',
      };
    } catch (e) {
      return null;
    }
  }

  /// 提交前让用户核对内容，并允许调整工时。
  ///
  /// 面向公司真实系统，绝不静默提交。
  /// 返回最终要提交的工时字符串；取消或输入非法时返回 null。
  ///
  /// 工时默认取打卡统计值，但必须可改：打卡异常、出差、补录等场景下
  /// 打卡值并不等于该报的工时，而这是唯一能在提交前修正它的地方。
  Future<String?> _confirmSubmit(
    String date,
    WorkLogEntry entry,
    WorkLogHours hours,
    double? existingHours,
    Map<String, String> constants,
  ) async {
    final alreadyFiled = existingHours != null && existingHours > 0;

    // 没有打卡数据时留空，由用户自己填，而不是拦在门外
    final punchText = hours.hasData
        ? WorkTimeCalculator.formatHours(hours.hours!)
        : '';
    final hoursController = TextEditingController(text: punchText);

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final parsed = WorkTimeCalculator.parseHoursInput(
            hoursController.text,
          );
          final edited = parsed != null && punchText.isNotEmpty &&
              WorkTimeCalculator.formatHours(parsed) != punchText;

          return AlertDialog(
            title: Text('提交 $date 的日志？'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // BOSS 不做去重，这里必须显式警示，否则会静默产生重复日志
                  if (alreadyFiled)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.warningLight,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.warning),
                      ),
                      child: Text(
                        '⚠️ 这一天在 BOSS 已填报 '
                        '${WorkTimeCalculator.formatHours(existingHours)} 小时。\n'
                        '继续提交会新增一条记录，不会覆盖原有记录。',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warningDark,
                        ),
                      ),
                    ),
                  if (existingHours == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        '未能确认当天是否已填报，请提交后自行核对。',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ),
                  // 项目与审核人是这里最有后果的两项：填错项目会把工时记到
                  // 别的项目名下，填错审核人会把日志提交给错误的审批人。
                  // 两者都不是用户输入的，而是 APP 自动查来的，因此必须让他能核对。
                  _confirmRow('项目', entry.projectName),
                  _confirmRow(
                    '审核人',
                    constants['auditorName']?.isNotEmpty == true
                        ? constants['auditorName']!
                        : '（未知，仅有 ID）',
                  ),
                  _confirmRow('标题', entry.title),
                  _confirmRow('工作类型', entry.workType),
                  _confirmRow('项目阶段', entry.stage),
                  _confirmRow('阶段活动', entry.activity),
                  _buildHoursField(
                    controller: hoursController,
                    punchText: punchText,
                    parsed: parsed,
                    edited: edited,
                    onChanged: () => setDialogState(() {}),
                  ),
                  const Divider(),
                  _confirmRow('工作内容', entry.content),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: const Text('取消'),
              ),
              FilledButton(
                // 工时非法时不给提交，避免把脏值发到公司系统
                onPressed: parsed == null
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        WorkTimeCalculator.formatHours(parsed),
                      ),
                // 已填报时改用「仍要提交」，让重复提交成为一个需要刻意确认的动作
                child: Text(alreadyFiled ? '仍要提交' : '确认提交'),
              ),
            ],
          );
        },
      ),
    );

    hoursController.dispose();
    return result;
  }

  /// 可编辑的工时输入行。
  ///
  /// 打卡值作为默认值和参照同时显示：改过之后仍能看到原始打卡工时是多少，
  /// 否则用户改完就无从判断自己偏离了多少。
  Widget _buildHoursField({
    required TextEditingController controller,
    required String punchText,
    required double? parsed,
    required bool edited,
    required VoidCallback onChanged,
  }) {
    final String helper;
    if (punchText.isEmpty) {
      helper = '当天没有打卡工时，请手动填写';
    } else if (edited) {
      helper = '打卡工时为 $punchText，已手动调整';
    } else {
      helper = '来自打卡统计，可修改';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '工时',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          TextField(
            controller: controller,
            autofocus: false,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              suffixText: '小时',
              helperText: parsed == null ? null : helper,
              helperStyle: TextStyle(
                fontSize: 10,
                color: edited ? AppColors.warningDark : Colors.grey[600],
              ),
              // 非法时说清楚合法范围，而不是只说「错了」
              errorText: parsed == null ? '请填 0 到 24 之间的数字' : null,
              errorStyle: const TextStyle(fontSize: 10),
            ),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(value.isEmpty ? '（空）' : value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// 同步当前月份的 BOSS 已填工时到本地，供月历页展示。
  ///
  /// 逐日请求（一个月约 30 次），因此执行期间给出等待提示。
  Future<void> _syncBossHours() async {
    final controller = _controller;
    if (controller == null) return;

    final date = widget.fillDate ?? DateHelper.getWorkDate();
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
        if (!mounted) return;
        _notify('未取到任何 BOSS 工时，请确认已登录并在页面上操作过一次');
        return;
      }

      await StorageService().saveBossHours(monthKey, hours);
      if (!mounted) return;
      _notify('已同步 $monthKey：${hours.length} 天有填报记录');
    } catch (e) {
      _notify('同步失败：$e');
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
    _notify('已清空抓包记录，现在去点「保存」，然后选「② 导出抓包」');
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
