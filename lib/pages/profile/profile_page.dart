import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../components/index.dart';

/// 底部导航第 4 项「我的」入口页。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) {
        final bottomPadding = AppPageScaffold.scrollableBottomPadding(
          context,
          hasBottomNav: useBottomNavigation,
        );
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '我的',
            showBackButton: !useBottomNavigation,
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () =>
                    Navigator.pushNamed(context, AppRoutes.settings),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              AppSettingSection(
                title: '更多',
                children: [
                  _navTile(
                    context,
                    icon: Icons.bar_chart_rounded,
                    title: '听歌统计',
                    subtitle: '本地播放数据概览',
                    route: AppRoutes.listeningStats,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '应用',
                children: [
                  _navTile(
                    context,
                    icon: Icons.settings_rounded,
                    title: '设置',
                    subtitle: '外观、播放器、通知等',
                    route: AppRoutes.settings,
                  ),
                  _navTile(
                    context,
                    icon: Icons.info_outline_rounded,
                    title: '版本信息',
                    subtitle: '版本号与调试日志',
                    route: AppRoutes.versionInfo,
                  ),
                ],
              ),
              const SizedBox(height: 32),
              // 退出登录按钮
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _logout(context),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('退出登录'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red, width: 0.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavIndex: useBottomNavigation ? 3 : null,
          onBottomNavTap: useBottomNavigation
              ? (index) => navigateToPrimaryDestination(context, index)
              : null,
        );
      },
    );
  }

  void _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AuthService.instance.logout();
      if (!context.mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.login);
    }
  }

  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingTile(
      title: title,
      subtitle: subtitle,
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: scheme.primary),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.pushNamed(context, route),
    );
  }
}
