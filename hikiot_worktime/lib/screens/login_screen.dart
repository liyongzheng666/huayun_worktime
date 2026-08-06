import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../core/theme/theme.dart';
import '../services/session_service.dart';
import '../services/storage_service.dart';
import 'main_screen.dart';

class LoginScreen extends StatefulWidget {
  /// 是否强制登出（清除 cookies 后再加载登录页）
  final bool forceLogout;

  const LoginScreen({super.key, this.forceLogout = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  InAppWebViewController? webViewController;
  double progress = 0;
  bool isLoading = true;
  bool _cookiesCleared = false;
  bool _isSavingToken = false;

  @override
  void initState() {
    super.initState();
    if (widget.forceLogout) {
      _clearCookiesFirst();
    } else {
      _cookiesCleared = true;
    }
  }

  Future<void> _clearCookiesFirst() async {
    await SessionService.clearHikiotCookies();
    if (mounted) {
      setState(() {
        _cookiesCleared = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 如果需要强制登出但 cookies 还没清除完，先显示加载
    if (widget.forceLogout && !_cookiesCleared) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('正在退出...'),
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('登录海康互联'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: '返回登录页',
            onPressed: () {
              webViewController?.loadUrl(
                urlRequest: URLRequest(
                  url: WebUri('https://www.hikiot.com/portal/login'),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              webViewController?.reload();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://www.hikiot.com/portal/login'),
            ),
            initialSettings: InAppWebViewSettings(
              // 基础设置
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,

              // 视口和缩放设置（关键修复）
              supportZoom: true,
              builtInZoomControls: false,
              displayZoomControls: false,
              useWideViewPort: true, // 使用宽视口
              loadWithOverviewMode: true, // 加载时自适应屏幕
              initialScale: 80, // 初始缩放80%，确保内容能完全显示
              // 媒体播放
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,

              // 导航设置
              useShouldOverrideUrlLoading: false,

              // 缓存和存储
              cacheEnabled: true,
              clearCache: false,
              thirdPartyCookiesEnabled: true, // 仅 Android 生效
              // iOS 专属：让 WKWebView 使用共享 Cookie 存储，默认为 false。
              // 开启后登录产生的 www_token 才能稳定被 CookieManager 读到并持久化。
              sharedCookiesEnabled: true,

              // 用户代理（模拟真实移动浏览器）
              userAgent:
                  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',

              // 其他优化
              useHybridComposition: true,
              disableVerticalScroll: false,
              disableHorizontalScroll: false,

              // 文本缩放
              minimumFontSize: 1,

              // 自动适配
              layoutAlgorithm: LayoutAlgorithm.NORMAL,
            ),
            // viewport 必须赶在首次渲染前设置。
            // 放在 onLoadStop 注入会先渲染出错误排版，而且 WKWebView 首屏后
            // 再改 initial-scale 不一定触发重新布局。Android 侧的
            // useWideViewPort/loadWithOverviewMode/initialScale 在 iOS 上
            // 全部无效，iOS 完全依赖这段脚本。
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                source: _viewportScript,
              ),
            ]),
            onWebViewCreated: (controller) {
              webViewController = controller;

              // 添加控制台日志监听，方便调试
              debugPrint('WebView已创建');
            },
            onLoadStart: (controller, url) {
              setState(() {
                isLoading = true;
              });
              debugPrint('开始加载: ${url?.toString()}');
            },
            onLoadStop: (controller, url) async {
              setState(() {
                isLoading = false;
              });
              debugPrint('加载完成: ${url?.toString()}');

              // 注入CSS优化移动端显示。
              // viewport 已由 AT_DOCUMENT_START 用户脚本处理，此处不再重复设置。
              await controller.evaluateJavascript(
                source: '''
                (function() {
                  // 添加CSS修复样式，确保内容不超出屏幕
                  var style = document.createElement('style');
                  style.textContent = `
                    * {
                      box-sizing: border-box !important;
                    }
                    html, body {
                      margin: 0 !important;
                      padding: 0 !important;
                      overflow-x: hidden !important;
                      width: 100% !important;
                      max-width: 100vw !important;
                    }
                    body > * {
                      max-width: 100% !important;
                    }
                    .container, [class*="container"] {
                      max-width: 100% !important;
                      padding-left: 10px !important;
                      padding-right: 10px !important;
                    }
                  `;
                  document.head.appendChild(style);

                  // 延迟100ms后重新调整
                  setTimeout(function() {
                    window.scrollTo(0, 0);
                    // 尝试让页面重新布局
                    document.body.style.width = '100%';
                  }, 100);
                })();
              ''',
              );

              // 输出实测布局数据，便于客观判断 iOS 排版是否溢出。
              await _checkLayout(controller);

              // 检查是否是登录后的页面
              if (url != null && !url.toString().contains('/login')) {
                // 可能已经登录，尝试提取Token
                await _tryExtractToken(controller);
              }
            },
            onProgressChanged: (controller, progress) {
              setState(() {
                this.progress = progress / 100;
              });
            },
            onConsoleMessage: (controller, consoleMessage) {
              // 输出网页控制台日志，帮助调试
              debugPrint('控制台: ${consoleMessage.message}');
            },
            onReceivedError: (controller, request, error) {
              debugPrint('加载错误: ${error.description}');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('加载错误: ${error.description}'),
                  backgroundColor: AppColors.error,
                ),
              );
            },
          ),
          if (isLoading)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    '加载中... ${(progress * 100).toInt()}%',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// viewport 修正脚本。
  ///
  /// AT_DOCUMENT_START 时 `document.head` 可能还不存在，因此回退到
  /// `documentElement`；页面自身之后可能再写一次 viewport，所以在
  /// DOMContentLoaded 时重新应用一次。
  static const String _viewportScript = '''
    (function() {
      var CONTENT = 'width=device-width, initial-scale=0.8, maximum-scale=5.0, user-scalable=yes';
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

  /// 布局自检：用实测数值代替肉眼判断，输出到日志。
  ///
  /// `overflow > 0` 表示内容宽度超出视口，即出现横向滚动条。
  Future<void> _checkLayout(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: '''
          (function() {
            var de = document.documentElement;
            var meta = document.querySelector('meta[name=viewport]');
            return JSON.stringify({
              scrollWidth: de.scrollWidth,
              innerWidth: window.innerWidth,
              overflow: de.scrollWidth - window.innerWidth,
              devicePixelRatio: window.devicePixelRatio,
              scale: (window.visualViewport && window.visualViewport.scale) || null,
              viewport: meta ? meta.getAttribute('content') : null
            });
          })();
        ''',
      );
      debugPrint('WebView 布局自检: $result');
    } catch (e) {
      debugPrint('WebView 布局自检失败: $e');
    }
  }

  /// 可能写入 www_token 的域名，与 SessionService 清理 Cookie 的域名保持一致。
  static const List<String> _tokenCookieUrls = [
    'https://www.hikiot.com',
    'https://hikiot.com',
    'https://api.hikiot.com',
  ];

  Future<void> _tryExtractToken(InAppWebViewController controller) async {
    try {
      // 优先读原生 Cookie 存储：iOS WKWebView 对 document.cookie 限制更严，
      // 且 HttpOnly Cookie 只有这条路径读得到。失败再回退到注入 JS。
      final token =
          await _readTokenFromCookieStore() ??
          await _readTokenFromDocumentCookie(controller);

      if (token != null) {
        await _saveTokenAndNavigate(token);
      }
    } catch (e) {
      // 提取Token失败
    }
  }

  /// 从 WebView 原生 Cookie 存储中读取 token。
  Future<String?> _readTokenFromCookieStore() async {
    final cookieManager = CookieManager.instance();

    for (final url in _tokenCookieUrls) {
      try {
        final cookies = await cookieManager.getCookies(url: WebUri(url));
        for (final cookie in cookies) {
          if (cookie.name != 'www_token') continue;
          final token = _normalizeExtractedToken(cookie.value);
          if (token != null) return token;
        }
      } catch (_) {
        // 单个域名读取失败不影响其余域名。
      }
    }

    return null;
  }

  /// 回退方案：注入 JS 读取 document.cookie。
  Future<String?> _readTokenFromDocumentCookie(
    InAppWebViewController controller,
  ) async {
    try {
      String js = '''
        (function() {
          var cookies = document.cookie.split(';');
          var token = null;
          for (var i = 0; i < cookies.length; i++) {
            var cookie = cookies[i].trim();
            if (cookie.startsWith('www_token=')) {
              token = cookie.substring('www_token='.length);
              break;
            }
          }
          return token;
        })();
      ''';

      return _normalizeExtractedToken(
        await controller.evaluateJavascript(source: js),
      );
    } catch (_) {
      return null;
    }
  }

  String? _normalizeExtractedToken(Object? result) {
    final token = result?.toString().trim();
    if (token == null || token.isEmpty || token.toLowerCase() == 'null') {
      return null;
    }
    return token;
  }

  Future<void> _saveTokenAndNavigate(String token) async {
    if (_isSavingToken || !mounted) return;
    _isSavingToken = true;

    try {
      // 保存Token到本地
      await StorageService().saveToken(token);

      // 显示成功提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('登录成功！'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 2),
          ),
        );

        // 延迟一下再跳转，让用户看到提示
        await Future.delayed(const Duration(seconds: 1));

        // 跳转到统计页面
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => MainScreen(token: token)),
          );
        }
      }
    } finally {
      _isSavingToken = false;
    }
  }
}
