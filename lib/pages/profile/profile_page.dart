import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
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
            showBackButton: !useBottomNavigation || AppLayoutSettings.isDesktop,
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
              // 当前账号卡片（点击进入账号切换页）
              const ProfileAccountCard(),
              const SizedBox(height: 20),
              // 「资源库」（专辑/歌手/风格）与「最近播放」已从这里移除：
              // 首页的快捷入口和功能卡片里都有，放两份只是重复。
              // 「账号管理」也去掉了：上面那张 ProfileAccountCard 点进去就是
              // 同一个 AppRoutes.accounts，两个入口紧挨着更像是漏删。
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
