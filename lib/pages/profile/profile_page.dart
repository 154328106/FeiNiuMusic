import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
import '../../app/router/app_router.dart' show AppRoutes;
import '../../app/services/netease/netease_api_client.dart';
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/services/source/netease_source.dart';
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
              const SizedBox(height: 12),
              const _MusicSourceSection(),
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

/// 音乐源切换。
///
/// 放在「我的」页账号卡片下面：换源只影响首页取哪家的数据，**不碰登录门控**
/// —— 飞牛账号仍是 App 的入口，网易云是叠加上去的第二个源。
class _MusicSourceSection extends StatelessWidget {
  const _MusicSourceSection();

  @override
  Widget build(BuildContext context) {
    final registry = MusicSourceRegistry.instance;
    // revision 也要监听：登录 / 登出后源没换，但「是否可用」变了。
    return ListenableBuilder(
      listenable: Listenable.merge([registry.current, registry.revision]),
      builder: (context, _) {
        final current = registry.current.value;
        return AppSettingSection(
          title: '音乐来源',
          children: [
            for (final source in MusicSourceRegistry.all)
              _SourceTile(
                source: source,
                selected: identical(source, current),
                onTap: () => _onTap(context, source, registry),
              ),
          ],
        );
      },
    );
  }

  /// 未登录的源点一下直接去登录，不用再翻设置页 —— 之前登录入口藏在
  /// 「设置 → 网易云音乐」的顶栏里，基本找不到。
  Future<void> _onTap(
    BuildContext context,
    MusicSource source,
    MusicSourceRegistry registry,
  ) async {
    if (!source.isAvailable && source.id == 'netease') {
      await Navigator.pushNamed(context, AppRoutes.neteaseLogin);
      NetEaseSource.instance.reset();
      // 登录成功就顺手切过去，省一步。
      //
      // 切换本身已经会让首页重拉，所以两条通知只能响一条：切过去就不再补
      // notifyContentChanged，否则 current 和 revision 前后脚各响一次，
      // 首页整整刷两遍（日志里所有行成对出现、请求量翻倍）。
      final willSwitch =
          NetEaseApiClient.instance.isLoggedIn &&
          !identical(registry.current.value, source);
      if (willSwitch) {
        await registry.setCurrent(source);
      } else {
        registry.notifyContentChanged();
      }
      return;
    }
    await registry.setCurrent(source);
  }
}

class _SourceTile extends StatelessWidget {
  final MusicSource source;
  final bool selected;
  final VoidCallback onTap;

  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = source.isAvailable;
    return AppSettingTile(
      title: source.label,
      // 不可用时把原因和下一步写在副标题上，而不是让用户切过去看到一片空白。
      subtitle: available
          ? (selected ? '当前使用中' : '点击切换')
          : '${source.unavailableHint} · 点击登录',
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          source.assetIcon,
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          // 资源缺失时退回图标，不至于整行报红。
          errorBuilder: (_, _, _) =>
              Icon(source.icon, size: 26, color: source.accent),
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_rounded, size: 20, color: scheme.primary)
          : null,
    );
  }
}
