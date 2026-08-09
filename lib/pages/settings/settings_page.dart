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
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '设置',
            showBackButton: !useBottomNavigation,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              AppSettingSection(
                title: '账号',
                children: [
                  AppSettingTile(
                    title: '账号管理',
                    subtitle: '切换、重命名或添加已保存的账号',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.accounts,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '外观',
                children: [
                  AppSettingTile(
                    title: '应用外观',
                    subtitle: '主题与背景设置',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.appAppearanceSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '播放器外观',
                    subtitle: '流光与播放主题',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.playerAppearanceSettings,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '功能',
                children: [
                  // 仅通过 FNID 连接时才显示：候选链路管理只对 FNID 探测有意义，
                  // 通过链接直连时该入口无意义。lastFnId 为空即链接连接。
                  if ((AppFnConnectionSettings.lastFnId ?? '').isNotEmpty)
                    AppSettingTile(
                      title: 'FN Connect',
                      subtitle: '连接偏好、当前连接与候选链路管理',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          AppRoutes.fnConnectSettings,
                        );
                      },
                    ),
                  AppSettingTile(
                    title: '播放器控制',
                    subtitle: '管理底部操作栏与按钮顺序',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.playerControlsSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '音量设置',
                    subtitle: '应用音量与定时音量',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.volumeScheduleSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '通知设置',
                    subtitle: '媒体通知显示与按钮偏好',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.notificationSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '权限管理',
                    subtitle: '查看通知、音频与后台播放权限',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.permissionSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '歌词设置',
                    subtitle: '控制歌词的呈现方式',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.lyricsSettings),
                  ),
                  AppSettingTile(
                    title: '元数据管理',
                    subtitle: '音乐元数据维护',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.metadataMatchSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '启动设置',
                    subtitle: '控制APP启动后的行为',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.launchSettings),
                  ),
                  AppSettingTile(
                    title: '缓存设置',
                    subtitle: '管理音频缓存与存储空间',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.cacheSettings),
                  ),
                  AppSettingTile(
                    title: '转码设置',
                    subtitle: '大文件/无损文件服务器转码播放',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.transcodeSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: 'DLNA',
                    subtitle: '将音乐推送到局域网 DLNA 设备',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.dlnaSettings),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '应用',
                children: [
                  AppSettingTile(
                    title: '版本信息',
                    subtitle: '版本号、检查更新与调试日志',
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
