import 'dart:async';

import 'package:flutter/material.dart';
import '../core/theme/theme.dart';
import '../services/app_update_service.dart';
import 'daily_hours_screen.dart';
import 'monthly_calendar_screen.dart';
import 'settings_screen.dart';
import 'work_log_screen.dart';
import '../utils/startup_refresh_coordinator.dart';
import '../widgets/home_button.dart';
import '../widgets/app_update_dialog.dart';
import '../models/today_wrap_up.dart';
import '../services/platform_capabilities.dart';

/// 主框架页面 - 包含底部导航栏
class MainScreen extends StatefulWidget {
  final String token;

  const MainScreen({super.key, required this.token});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final AppUpdateService _appUpdateService = AppUpdateService();

  final GlobalKey<MonthlyCalendarScreenState> _monthlyKey = GlobalKey();
  final GlobalKey<DailyHoursScreenState> _dailyKey = GlobalKey();
  final GlobalKey<WorkLogScreenState> _workLogKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 应用启动时自动刷新数据
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartupRefresh());
      unawaited(_checkForUpdateSilently());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshVisibleBossData());
    }
  }

  Future<void> _refreshVisibleBossData() async {
    if (_currentIndex == 1) {
      await _monthlyKey.currentState?.refreshBossHoursSilently();
    } else if (_currentIndex == 2) {
      await _workLogKey.currentState?.refreshBossHoursSilently();
    }
  }

  Future<void> _checkForUpdateSilently() async {
    if (!_appUpdateService.isSupported) return;
    try {
      await _appUpdateService.cleanupStaleDownloads();
      final update = await _appUpdateService.checkForUpdate();
      if (!mounted || update == null) return;
      await showAppUpdateDialog(
        context: context,
        service: _appUpdateService,
        update: update,
      );
    } catch (_) {
      // 启动期检查失败必须静默，不能让 GitHub 网络影响核心功能。
    }
  }

  Future<void> _runStartupRefresh() async {
    await StartupRefreshCoordinator.run(
      initializeSession: () async {
        await _monthlyKey.currentState?.initializeUserContext();
      },
      refreshDaily: () async {
        await _dailyKey.currentState?.refreshData();
      },
      refreshMonthly: () async {
        await _monthlyKey.currentState?.smartUpdate();
      },
      isMounted: () => mounted,
    );
    if (mounted) await _dailyKey.currentState?.refreshMonthCache();
  }

  Future<void> _onTabTap(int index) async {
    setState(() {
      _currentIndex = index;
    });

    // 切换到每日页面时,刷新数据（包括从月度页面修改的手动标记）
    if (index == 0 && _dailyKey.currentState != null) {
      _dailyKey.currentState!.refreshData();
    }

    // 切换到每月页面时,从存储刷新数据（包括从每日页面修改的手动标记）
    if (index == 1 && _monthlyKey.currentState != null) {
      final selectedDate = _dailyKey.currentState?.selectedDate;
      await _monthlyKey.currentState!.refreshFromStorage();
      if (selectedDate != null) {
        await _monthlyKey.currentState!.refreshDateData(selectedDate);
      }
    }

    // 切换到工作日志页时刷新，确保工时与前两页口径一致
    if (index == 2 && _workLogKey.currentState != null) {
      await _workLogKey.currentState!.refreshData();
    }
  }

  /// 今日卡片直达原有导入、登录和提交确认流程，不绕过核对环节。
  Future<void> _openWrapUpTask(TodayWrapUpAction action, DateTime date) async {
    if (!mounted) return;
    setState(() => _currentIndex = 2);
    await _workLogKey.currentState?.handleWrapUpAction(date, action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          DailyHoursScreen(
            key: _dailyKey,
            autoLoad: false,
            onWrapUpAction: _openWrapUpTask,
          ),
          MonthlyCalendarScreen(
            key: _monthlyKey,
            token: widget.token,
            autoInitialize: false,
          ),
          WorkLogScreen(key: _workLogKey),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: PlatformCapabilities.supportsTodayWrapUp
          ? _buildIosNavigation()
          : Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadow,
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildNavItem(0, Icons.today, '每日工时'),
                      _buildNavItem(1, Icons.calendar_month, '月度统计'),
                      _buildNavItem(2, Icons.edit_note, '工作日志'),
                      _buildNavItem(3, Icons.settings, '设置'),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildIosNavigation() {
    final colors = Theme.of(context).colorScheme;
    const labels = ['今日', '月度', '日志', '我的'];
    const icons = [
      Icons.today_outlined,
      Icons.bar_chart_outlined,
      Icons.description_outlined,
      Icons.person_outline,
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == _currentIndex,
                    child: InkWell(
                      onTap: () => _onTabTap(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              icons[i],
                              size: 24,
                              color: i == _currentIndex
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              labels[i],
                              style: TextStyle(
                                fontSize: 11,
                                color: i == _currentIndex
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建单个导航项 - 支持 Home 键风格的按压反馈
  Widget _buildNavItem(int index, IconData icon, String label) {
    final theme = Theme.of(context);
    final isSelected = _currentIndex == index;

    final color = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Expanded(
      child: HomeButton(
        onPressed: () => _onTabTap(index),
        backgroundColor: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        pressedBackgroundColor: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : theme.colorScheme.primary.withValues(alpha: 0.05),
        pressedScale: 0.92,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: isSelected ? 26 : 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
