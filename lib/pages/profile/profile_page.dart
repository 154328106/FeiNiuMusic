import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
import '../../app/router/app_router.dart' show AppRoutes;
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
                    assetIcon: 'assets/icon/stats.png',
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

  /// [assetIcon] 给了就用图片，[icon] 退为加载失败时的兜底。
  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required String route,
    String? assetIcon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingTile(
      title: title,
      subtitle: subtitle,
      leading: assetIcon != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset(
                assetIcon,
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(icon, size: 20, color: scheme.primary),
              ),
            )
          : Container(
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
                onLogin: source.id == 'netease'
                    ? () => _onLogin(context, registry)
                    : null,
              ),
          ],
        );
      },
    );
  }

  /// 点整行 = 切换到这个源。登录与否不影响切换：网易云不登录也能听
  /// 推荐新歌、推荐歌单和排行榜。登录走右侧那个单独的按钮。
  Future<void> _onTap(
    BuildContext context,
    MusicSource source,
    MusicSourceRegistry registry,
  ) async {
    await registry.setCurrent(source);
  }

  /// 右侧「登录 / 账号」按钮：扫码登录，回来后刷新这一行和首页。
  Future<void> _onLogin(
    BuildContext context,
    MusicSourceRegistry registry,
  ) async {
    await Navigator.pushNamed(context, AppRoutes.neteaseLogin);
    NetEaseSource.instance.reset();
    // 登录态变了，首页的收藏 / 最近播放要重拉。源没换，所以只发内容变更。
    registry.notifyContentChanged();
  }
}

class _SourceTile extends StatelessWidget {
  final MusicSource source;
  final bool selected;
  final VoidCallback onTap;

  /// 需要账号的源给一个单独的登录入口；为 null 表示这个源不谈登录。
  final VoidCallback? onLogin;

  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
    this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = source.isAvailable;
    final loggedIn = source is NetEaseSource ? source.isLoggedIn : true;
    return AppSettingTile(
      title: source.label,
      // 不可用时把原因和下一步写在副标题上，而不是让用户切过去看到一片空白。
      subtitle: !available
          ? '${source.unavailableHint} · 点击登录'
          : loggedIn
          ? (selected ? '当前使用中' : '点击切换')
          : '未登录，只有推荐和排行榜${selected ? '' : ' · 点击切换'}',
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onLogin != null)
            TextButton(
              onPressed: onLogin,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(loggedIn ? '账号' : '登录'),
            ),
          if (selected)
            Icon(Icons.check_rounded, size: 20, color: scheme.primary),
        ],
      ),
    );
  }
}
