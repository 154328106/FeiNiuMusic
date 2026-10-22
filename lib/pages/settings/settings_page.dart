import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../player/widgets/player_background.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    PlayerBackgroundSettings.ensureLoaded();
    AppPlaybackVolumeSettings.ensureLoaded();
    PlayerBottomActionSettings.ensureLoaded();
    MediaNotificationSettings.ensureLoaded();
    StatusBarSettings.ensureLoaded();
    AppLayoutSettings.ensureLoaded();
    AppBackgroundSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) {
        final bottomPadding = AppPageScaffold.scrollableBottomPadding(
          context,
          hasBottomNav: useBottomNavigation,
          showMiniPlayer: false,
        );
        final scheme = Theme.of(context).colorScheme;
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '设置',
            // 设置页永远是压栈进来的，必须给返回入口：iOS 没有系统返回键，
            // 之前底部栏模式下不显示，进来就出不去了。
            // automaticallyImplyLeading 在无法 pop 时本就不渲染，恒 true 安全。
            showBackButton: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              // 「账号管理」只留在「我的」页面顶部那张账号卡片上；「外观」整个单元
              // 搬到了「我的」页（见 ThemeAppearanceSection），这里不再重复。
              //
              // 「主题外观」从「我的」页搬到设置页最上方（功能设置之上）。
              _CollapsibleSection(
                title: '主题外观',
                icon: Icons.palette_outlined,
                collapsedSubtitle: '应用外观 · 播放器外观 · 播放器控制',
                accent: scheme.secondary,
                children: [
                  _navSub(
                    context,
                    icon: Icons.color_lens_outlined,
                    title: '应用外观',
                    subtitle: '主题与背景设置',
                    route: AppRoutes.appAppearanceSettings,
                  ),
                  _navSub(
                    context,
                    icon: Icons.play_circle_outline_rounded,
                    title: '播放器外观',
                    subtitle: '流光与播放主题',
                    route: AppRoutes.playerAppearanceSettings,
                  ),
                  _navSub(
                    context,
                    icon: Icons.tune_rounded,
                    title: '播放器控制',
                    subtitle: '管理底部操作栏与按钮顺序',
                    route: AppRoutes.playerControlsSettings,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 「功能」里一长串入口平时只偶尔动，全摊开占满整屏。照「主题外观」
              // 做成可折叠：平时一行，点开才露出来。
              _CollapsibleSection(
                title: '功能设置',
                icon: Icons.widgets_outlined,
                collapsedSubtitle: '音量 · 通知 · 权限 · 元数据 · 启动 · 缓存 · DLNA',
                accent: scheme.secondary,
                children: [
                  // 仅通过 FNID 连接时才显示：候选链路管理只对 FNID 探测有意义，
                  // 通过链接直连时该入口无意义。lastFnId 为空即链接连接。
                  if ((AppFnConnectionSettings.lastFnId ?? '').isNotEmpty)
                    _navSub(
                      context,
                      icon: Icons.hub_outlined,
                      title: 'FN Connect',
                      subtitle: '连接偏好、当前连接与候选链路管理',
                      route: AppRoutes.fnConnectSettings,
                    ),
                  // 「播放器控制」也归到「我的 → 主题外观」里了。
                  _navSub(
                    context,
                    icon: Icons.volume_up_outlined,
                    title: '音量设置',
                    subtitle: '应用音量与定时音量',
                    route: AppRoutes.volumeScheduleSettings,
                  ),
                  // 通知设置（媒体通知/通知歌词/悬浮窗）依赖 Android 媒体会话
                  // 与系统通知，桌面端无对应能力，隐藏入口。
                  if (Platform.isAndroid)
                    _navSub(
                      context,
                      icon: Icons.notifications_outlined,
                      title: '通知设置',
                      subtitle: '媒体通知显示与按钮偏好',
                      route: AppRoutes.notificationSettings,
                    ),
                  // 权限管理仅 Android 有对应系统权限，桌面端隐藏入口。
                  if (Platform.isAndroid)
                    _navSub(
                      context,
                      icon: Icons.verified_user_outlined,
                      title: '权限管理',
                      subtitle: '查看通知、音频与后台播放权限',
                      route: AppRoutes.permissionSettings,
                    ),
                  // 元数据管理（数据源搜索匹配）依赖服务端增强（FnMusicEnhance），
                  // 后端可达即可用（含 Windows 桌面端）。
                  _navSub(
                    context,
                    icon: Icons.description_outlined,
                    title: '元数据管理',
                    subtitle: '音乐元数据维护',
                    route: AppRoutes.metadataMatchSettings,
                  ),
                  _navSub(
                    context,
                    icon: Icons.rocket_launch_outlined,
                    title: '启动设置',
                    subtitle: '控制APP启动后的行为',
                    route: AppRoutes.launchSettings,
                  ),
                  _navSub(
                    context,
                    icon: Icons.sd_storage_outlined,
                    title: '缓存设置',
                    subtitle: '管理音频缓存与存储空间',
                    route: AppRoutes.cacheSettings,
                  ),
                  _navSub(
                    context,
                    icon: Icons.cast_outlined,
                    title: 'DLNA',
                    subtitle: '将音乐推送到局域网 DLNA 设备',
                    route: AppRoutes.dlnaSettings,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 「音源」单独一栏，点一下直接进音源配置页（开关/配置/LX/诊断都在里面）。
              AppSettingSection(
                children: [
                  AppSettingTile(
                    title: '音源配置',
                    subtitle: '音源开关 · 密钥配置 · LX 脚本',
                    leading: Icon(
                      Icons.library_music_outlined,
                      size: 22,
                      color: scheme.primary,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.unblockSource),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (Platform.isMacOS)
                AppSettingSection(
                  title: '桌面端',
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: StatusBarSettings.enabled,
                      builder: (context, enabled, _) {
                        return AppSettingSwitchTile(
                          title: '状态栏播放状态',
                          subtitle: '播放时显示当前歌词，无歌词或暂停时显示歌曲名',
                          value: enabled,
                          onChanged: (value) {
                            StatusBarSettings.setEnabled(value);
                          },
                        );
                      },
                    ),
                  ],
                ),
              if (Platform.isMacOS) const SizedBox(height: 16),
              // 转码设置、歌词设置从「功能设置」里拎出来，放在音源配置下面、数据备份上面。
              AppSettingSection(
                children: [
                  AppSettingTile(
                    title: '转码设置',
                    subtitle: '大文件/无损文件服务器转码播放',
                    leading: Icon(
                      Icons.transform_outlined,
                      size: 22,
                      color: scheme.primary,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.transcodeSettings,
                    ),
                  ),
                ],
              ),
              // 歌词设置依赖 Android 系统级通知与媒体会话，桌面端无对应能力。
              if (Platform.isAndroid) ...[
                const SizedBox(height: 16),
                AppSettingSection(
                  children: [
                    AppSettingTile(
                      title: '歌词设置',
                      subtitle: '控制歌词的呈现方式',
                      leading: Icon(
                        Icons.lyrics_outlined,
                        size: 22,
                        color: scheme.primary,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.lyricsSettings),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // 数据备份、调试模式各自单独一行（原来合在「应用」一组里）。
              AppSettingSection(
                children: [
                  AppSettingTile(
                    title: '数据备份',
                    subtitle: '备份账号、听歌统计与设置到本地或 WebDAV',
                    leading: Icon(
                      Icons.backup_outlined,
                      size: 22,
                      color: scheme.primary,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.backupRestore),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                children: [
                  AppSettingTile(
                    title: '调试模式',
                    subtitle: '调试日志的开关、清空与导出',
                    leading: Icon(
                      Icons.bug_report_outlined,
                      size: 22,
                      color: scheme.primary,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.versionInfo),
                  ),
                ],
              ),
            ],
          ),
          bottomNavIndex: null,
          showMiniPlayer: false,
        );
      },
    );
  }
}

/// 折叠项：带命名路由的子入口（左侧缩进，视觉上从属于上面的分组头）。
Widget _navSub(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required String route,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(left: 16),
    child: AppSettingTile(
      title: title,
      subtitle: subtitle,
      leading: Icon(icon, size: 20, color: scheme.primary),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.pushNamed(context, route),
    ),
  );
}

/// 可折叠分组——一个格子，点开露出里面的入口，再点收起。
///
/// 照搬「我的 → 主题外观」那套（profile_page 的 _ThemeAppearanceSection）：
/// 一行分组头 + 跟随状态旋转的箭头，底下用 AnimatedSize 把子项滑出/收回。
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection({
    required this.title,
    required this.icon,
    required this.collapsedSubtitle,
    required this.children,
    this.accent,
  });

  final String title;
  final IconData icon;

  /// 收起时分组头的副标题（展开时显示「收起」）。
  final String collapsedSubtitle;
  final List<Widget> children;
  final Color? accent;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingSection(
      title: widget.title,
      accent: widget.accent,
      children: [
        AppSettingTile(
          title: widget.title,
          subtitle: _expanded ? '收起' : widget.collapsedSubtitle,
          leading: Icon(widget.icon, size: 22, color: scheme.primary),
          // 箭头跟着状态转，一眼能看出是「能展开的」而不是「点进去的」。
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.chevron_right_rounded),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        // 展开/收起是滑出来的，不是硬跳。
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(children: widget.children)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
