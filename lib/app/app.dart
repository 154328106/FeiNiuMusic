import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

import '../components/dialog/app_update_dialog.dart';
import '../components/layout/tablet_layout_host.dart';
import '../pages/login/login_page.dart';
import '../pages/onboarding/onboarding_page.dart';
import 'navigator_key.dart';
import 'router/app_page_route.dart';
import 'router/app_router.dart';
import 'services/app_update_service.dart';
import 'services/feiniu/account_store.dart';
import 'services/feiniu/auth_service.dart';
import 'state/settings_state.dart';
import 'theme/app_styles.dart';
import 'theme/app_visual_theme.dart';
import 'utils/route_visibility.dart';

class FeiNiuMusicApp extends StatelessWidget {
  const FeiNiuMusicApp({super.key});

  ThemeData _applyDynamic(
    ThemeData base,
    ColorScheme? scheme,
    AppVisualStyle visualStyle,
  ) {
    final appliedScheme = scheme ?? base.colorScheme;
    if (visualStyle == AppVisualStyle.miuix) {
      return buildMiuixMaterialTheme(base, appliedScheme);
    }
    final isDark = base.brightness == Brightness.dark;

    final scaffoldBg = isDark
        ? Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.04),
            appliedScheme.surface,
          )
        : Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.06),
            appliedScheme.surface,
          );

    final panelColor = isDark
        ? Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.08),
            appliedScheme.surfaceContainerHigh,
          )
        : Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.12),
            Colors.white,
          );

    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.35)
        : appliedScheme.primary.withValues(alpha: 0.16);

    return base.copyWith(
      colorScheme: appliedScheme,
      primaryColor: appliedScheme.primary,
      scaffoldBackgroundColor: scaffoldBg,
      cardColor: panelColor,
      cardTheme: base.cardTheme.copyWith(
        color: panelColor,
        shadowColor: shadowColor,
        elevation: 0,
      ),
      dialogTheme: base.dialogTheme.copyWith(backgroundColor: panelColor),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: panelColor,
        modalBackgroundColor: panelColor,
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        foregroundColor: appliedScheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return ValueListenableBuilder<AppVisualStyle>(
          valueListenable: AppThemeSettings.visualStyle,
          builder: (context, visualStyle, _) {
            return ValueListenableBuilder<ThemeMode>(
              valueListenable: AppThemeSettings.themeMode,
              builder: (context, mode, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: AppThemeSettings.dynamicColorEnabled,
                  builder: (context, dynamicEnabled, _) {
                    return ValueListenableBuilder<Color?>(
                      valueListenable: AppThemeSettings.themeSeedColor,
                      builder: (context, seedColor, _) {
                        final baseSeed = seedColor ?? const Color(0xFF3B82F6);
                        final lightBase = ThemeData(
                          colorScheme: ColorScheme.fromSeed(
                            seedColor: baseSeed,
                            brightness: Brightness.light,
                          ),
                          useMaterial3: true,
                          pageTransitionsTheme: const PageTransitionsTheme(
                            builders: {
                              TargetPlatform.android:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.iOS: CoverPageTransitionsBuilder(),
                              TargetPlatform.macOS:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.windows:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.linux:
                                  CoverPageTransitionsBuilder(),
                            },
                          ),
                        );
                        final darkBase = ThemeData(
                          colorScheme: ColorScheme.fromSeed(
                            seedColor: baseSeed,
                            brightness: Brightness.dark,
                          ),
                          useMaterial3: true,
                          pageTransitionsTheme: const PageTransitionsTheme(
                            builders: {
                              TargetPlatform.android:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.iOS: CoverPageTransitionsBuilder(),
                              TargetPlatform.macOS:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.windows:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.linux:
                                  CoverPageTransitionsBuilder(),
                            },
                          ),
                        );
                        final lightTheme = _applyDynamic(
                          lightBase,
                          dynamicEnabled ? lightDynamic : null,
                          visualStyle,
                        );
                        final darkTheme = _applyDynamic(
                          darkBase,
                          dynamicEnabled ? darkDynamic : null,
                          visualStyle,
                        );
                        final routes = AppRouter.routes;
                        Route<dynamic> onGenerateRoute(RouteSettings settings) {
                          final name = settings.name ?? AppRoutes.home;
                          final target =
                              routes[name] ?? routes[AppRoutes.home]!;
                          return buildAppPageRoute<dynamic>(
                            target,
                            settings: settings,
                          );
                        }

                        return MaterialApp(
                          title: '飞牛音乐',
                          navigatorKey: appNavigatorKey,
                          theme: lightTheme,
                          darkTheme: darkTheme,
                          themeMode: mode,
                          scrollBehavior: const AppScrollBehavior(),
                          home: _AppStartupGate(
                            onGenerateRoute: onGenerateRoute,
                          ),
                          onGenerateRoute: onGenerateRoute,
                          builder: (context, child) {
                            final theme = Theme.of(context);
                            final isDark = theme.brightness == Brightness.dark;
                            final navColor = theme.colorScheme.surface;
                            final overlay = SystemUiOverlayStyle(
                              statusBarColor: Colors.transparent,
                              statusBarIconBrightness: isDark
                                  ? Brightness.light
                                  : Brightness.dark,
                              statusBarBrightness: isDark
                                  ? Brightness.dark
                                  : Brightness.light,
                              systemNavigationBarColor: navColor,
                              systemNavigationBarIconBrightness: isDark
                                  ? Brightness.light
                                  : Brightness.dark,
                              systemNavigationBarDividerColor: navColor,
                            );
                            Widget content =
                                AnnotatedRegion<SystemUiOverlayStyle>(
                                  value: overlay,
                                  child: child ?? const SizedBox.shrink(),
                                );
                            if (visualStyle == AppVisualStyle.miuix) {
                              final shadMode = switch (mode) {
                                ThemeMode.light => shad.ThemeMode.light,
                                ThemeMode.dark => shad.ThemeMode.dark,
                                ThemeMode.system => shad.ThemeMode.system,
                              };
                              content = shad.ShadcnLayer(
                                theme: buildMiuixShadTheme(
                                  lightTheme.colorScheme,
                                ),
                                darkTheme: buildMiuixShadTheme(
                                  darkTheme.colorScheme,
                                ),
                                themeMode: shadMode,
                                scaling: const shad.AdaptiveScaling(),
                                child: content,
                              );
                            }
                            return content;
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// APP 启动门控
///
/// 登录状态切换门控：
/// - 未登录 → LoginPage
/// - 已登录 → 直接进主页面（后台探测在 main() 中异步执行，不阻塞首页渲染）
class _AppStartupGate extends StatefulWidget {
  final Route<dynamic> Function(RouteSettings) onGenerateRoute;

  const _AppStartupGate({required this.onGenerateRoute});

  @override
  State<_AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<_AppStartupGate> {
  bool _scheduledAutoCheck = false;
  bool _scheduledAutoOpenPlayer = false;

  /// 当前账号对应的嵌套基础 Navigator key（随账号变化重建）。
  /// 自动打开播放页必须压到该嵌套导航器上（门控自身的 context 会解析到根
  /// 导航器，压根导航器会盖住门控，破坏登录/登出回退到门控的规则）。
  GlobalKey<NavigatorState>? _baseNavKey;

  @override
  Widget build(BuildContext context) {
    // 首次启动引导门控：未完成引导一律全屏显示，与登录态无关；
    // 完成后（completed=true）才进入下方登录/外壳逻辑。
    return ValueListenableBuilder<bool>(
      valueListenable: AppOnboardingSettings.completed,
      builder: (context, onboardingCompleted, _) {
        if (!onboardingCompleted) {
          return const OnboardingPage();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AuthService.instance.isLoggedIn,
          builder: (context, isLoggedIn, _) {
            if (!isLoggedIn) {
              return const LoginPage();
            }
            // 已登录进入主界面：首帧后自动检查更新（仅一次/会话，开关开启且有
            // 新版本才弹窗，不阻塞渲染）。登录后才触发，避免登录页被更新弹窗遮挡。
            if (!_scheduledAutoCheck) {
              _scheduledAutoCheck = true;
              _scheduleAutoCheckUpdate();
            }
            // 启动后自动打开播放界面：在门控（非登录态）首帧后跳转，覆盖
            // 抽屉/底部栏/平板所有导航模式。仅本次 session 首次生效；
            // 切换账号重建外壳不会重复跳转。
            if (!_scheduledAutoOpenPlayer) {
              _scheduledAutoOpenPlayer = true;
              _scheduleAutoOpenPlayer();
            }
            // 切换账号时 isLoggedIn 保持 true（门控不重建），但整个外壳需按当前
            // 账号重建：给外壳换 key → 所有存活页面卸载重建 → initState 重跑 →
            // 用新 token/服务器地址拉取数据；导航栈同时重置回首页。
            // 注意：嵌套 Navigator 的 GlobalKey 必须随账号变化（GlobalObjectKey 值相等性）。
            // 若沿用固定的 baseNavigatorKey，Flutter 会把旧 Navigator 连同整个页面树
            // reparent 到新子树（GlobalKey 重挂），页面不会重挂载、数据不会刷新。
            return ValueListenableBuilder<String?>(
              valueListenable: AccountStore.instance.currentAccountId,
              builder: (context, accountId, _) {
                final navKey = GlobalObjectKey<NavigatorState>(
                  'base-nav-${accountId ?? 'none'}',
                );
                _baseNavKey = navKey;
                return KeyedSubtree(
                  key: ValueKey('shell-${accountId ?? 'none'}'),
                  child: TabletLayoutHost(
                    navigatorKey: navKey,
                    child: Navigator(
                      key: navKey,
                      // 挂载 appRouteObserver：应用内所有路由都在此嵌套 Navigator
                      // 上，注册后 AppRouteVisibilityMixin（didPushNext/didPopNext）
                      // 才能按文档生效，播放页/流光预览的路由可见性暂停才有意义。
                      observers: [appRouteObserver],
                      initialRoute: AppRouter.initialRoute,
                      onGenerateRoute: widget.onGenerateRoute,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 启动后延迟自动检查更新：给首页首帧留出渲染空间，检查在后台静默进行，
  /// 有新版本时才弹窗提示。整个会话只检查一次。
  void _scheduleAutoCheckUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _autoCheckUpdate();
    });
  }

  /// 启动后自动打开播放界面：用户开启该开关时，给首帧留出渲染空间后
  /// 再压栈播放页（仅本次 session 首次）。放在门控而非各页面/外壳里，
  /// 确保抽屉 / 底部栏 / 平板等所有导航模式都能生效。
  ///
  /// 必须压到当前账号的嵌套基础导航器上，不能压根导航器（根导航器会被
  /// 门控盖住，破坏登录/登出回退到门控的规则）。
  void _scheduleAutoOpenPlayer() {
    if (!AppLaunchNavigationSettings.autoOpenPlayerOnLaunch.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = _baseNavKey?.currentState;
      if (nav == null) return;
      nav.pushNamed(AppRoutes.player);
    });
  }

  Future<void> _autoCheckUpdate() async {
    await AppLaunchUpdateSettings.ensureLoaded();
    if (!AppLaunchUpdateSettings.autoCheckUpdateOnLaunch.value) return;
    if (AppLaunchUpdateSettings.hasCheckedUpdateThisSession) return;
    AppLaunchUpdateSettings.hasCheckedUpdateThisSession = true;
    try {
      final current = await AppUpdateService.instance.currentVersion();
      final info = await AppUpdateService.instance.checkLatest(current);
      if (!mounted || !info.hasUpdate) return;
      await showAppUpdateDialog(
        context,
        info: info,
        currentVersion: current,
      );
    } catch (_) {
      // 静默失败：自动检查失败不打扰用户，手动检查仍可用
    }
  }
}
