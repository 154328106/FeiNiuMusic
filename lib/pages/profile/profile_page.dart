import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
import '../../app/router/app_router.dart' show AppRoutes;
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/services/kugou/kugou_auth.dart';
import '../../app/services/kugou/kugou_playback_service.dart';
import '../../app/services/qq/qq_auth.dart';
import '../../app/services/qq/qq_playback_service.dart';
import '../../app/services/source/netease_source.dart';
import '../../app/services/source/kugou_source.dart';
import '../../app/services/source/qq_source.dart';
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
              const SizedBox(height: 12),
              const _ThemeAppearanceSection(),
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
          // 32×32 + 圆角 8：和「音乐来源」那排保持一致。原来 38 明显大一圈，
          // 两块挨着看很别扭。
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                assetIcon,
                width: 32,
                height: 32,
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

/// 「主题外观」——一个格子，点开露出三项，再点收起。
///
/// 这三项原本埋在「设置 → 外观 / 功能」里，是最常调的东西，翻两层才够到。
/// 搬到「我的」页并做成折叠：平时只占一行，不跟音乐来源抢版面。
class _ThemeAppearanceSection extends StatefulWidget {
  const _ThemeAppearanceSection();

  @override
  State<_ThemeAppearanceSection> createState() =>
      _ThemeAppearanceSectionState();
}

class _ThemeAppearanceSectionState extends State<_ThemeAppearanceSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingSection(
      title: '主题外观',
      children: [
        AppSettingTile(
          title: '主题外观',
          subtitle: _expanded ? '收起' : '应用外观 · 播放器外观 · 播放器控制',
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/icon/theme.png',
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.palette_rounded, size: 22, color: scheme.primary),
            ),
          ),
          // 箭头跟着状态转，一眼能看出是「能展开的」而不是「点进去的」。
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.chevron_right_rounded),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        // 展开的三项。用 AnimatedSize 让展开/收起是滑出来的，不是硬跳。
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  children: [
                    _subTile(
                      context,
                      icon: Icons.color_lens_outlined,
                      title: '应用外观',
                      subtitle: '主题与背景设置',
                      route: AppRoutes.appAppearanceSettings,
                    ),
                    _subTile(
                      context,
                      icon: Icons.play_circle_outline_rounded,
                      title: '播放器外观',
                      subtitle: '流光与播放主题',
                      route: AppRoutes.playerAppearanceSettings,
                    ),
                    _subTile(
                      context,
                      icon: Icons.tune_rounded,
                      title: '播放器控制',
                      subtitle: '管理底部操作栏与按钮顺序',
                      route: AppRoutes.playerControlsSettings,
                    ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// 展开项：左侧留出一段缩进，视觉上从属于上面那行。
  Widget _subTile(
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
                onLogin: switch (source.id) {
                  'netease' => () => _onLogin(context, registry),
                  'qq' => () => _onLoginQQ(context, registry),
                  'kugou' => () => _onLoginKugou(context, registry),
                  _ => null,
                },
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
    // 飞牛还没连上就切过去，首页只会是一片空白 —— 先去添加账号。
    // 访客模式进来的人就是这个状态。
    if (source.id == 'feiniu' && !source.isAvailable) {
      await Navigator.pushNamed(context, AppRoutes.accounts);
      return;
    }
    await registry.setCurrent(source);
  }

  /// QQ 扫码登录。登录后能听会员曲、拿更高音质。
  Future<void> _onLoginQQ(
    BuildContext context,
    MusicSourceRegistry registry,
  ) async {
    if (QQAuth.instance.isLoggedIn.value) {
      final logout = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('扣扣音乐账号'),
          content: Text(
            '已登录${QQAuth.instance.nickname.isEmpty ? '' : '：${QQAuth.instance.nickname}'}。'
            '退出后仍可用推荐、榜单和搜索，但会员曲和高音质拿不到。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出登录'),
            ),
          ],
        ),
      );
      if (logout != true) return;
      await QQAuth.instance.logout();
      // 换了登录态，之前判定「拿不到地址」的那批歌值得重试一次。
      QQPlaybackService.instance.clear();
      QQSource.instance.reset();
      registry.notifyContentChanged();
      return;
    }
    await Navigator.pushNamed(context, AppRoutes.qqLogin);
    QQPlaybackService.instance.clear();
    QQSource.instance.reset();
    registry.notifyContentChanged();
  }

  /// 酷狗扫码登录。登录后能听会员曲，还能同步云端歌单和「我喜欢」。
  Future<void> _onLoginKugou(
    BuildContext context,
    MusicSourceRegistry registry,
  ) async {
    final auth = KugouAuth.instance;
    if (auth.isLoggedIn.value) {
      final logout = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('酷狗音乐账号'),
          content: Text(
            '已登录${auth.nickname.isEmpty ? '' : '：${auth.nickname}'}。'
            '退出后仍可用推荐、榜单和搜索，但会员曲和云端歌单拿不到。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出登录'),
            ),
          ],
        ),
      );
      if (logout != true) return;
      await auth.logout();
      // 换了登录态，之前判定「拿不到地址」的那批歌值得重试一次。
      KugouPlaybackService.instance.clear();
      KugouSource.instance.reset();
      registry.notifyContentChanged();
      return;
    }
    await Navigator.pushNamed(context, AppRoutes.kugouLogin);
    KugouPlaybackService.instance.clear();
    KugouSource.instance.reset();
    registry.notifyContentChanged();
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
    // 先落到局部变量再判类型：Dart 不对字段做类型提升（字段可能被 getter
    // 覆盖），直接 `source is NetEaseSource ? source.isLoggedIn : ...` 编译不过。
    final src = source;
    final loggedIn = switch (src) {
      NetEaseSource() => src.isLoggedIn,
      QQSource() => QQAuth.instance.isLoggedIn.value,
      KugouSource() => KugouAuth.instance.isLoggedIn.value,
      _ => true,
    };
    return AppSettingTile(
      title: source.label,
      // 不可用时把原因和下一步写在副标题上，而不是让用户切过去看到一片空白。
      // 只说「在用 / 能切」。登录与否右边的按钮已经写着了，副标题再解释
      // 一遍是重复；不可用的原因也没必要占一行 —— 点进去自然会引导。
      subtitle: selected ? '当前使用中' : '点击切换',
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
          // 勾位固定占宽：不占的话，选中那行的按钮会被勾挤走 20 像素，
          // 上下几行的「账号 / 登录」就对不齐了。
          SizedBox(
            width: 20,
            child: selected
                ? Icon(Icons.check_rounded, size: 20, color: scheme.primary)
                : null,
          ),
        ],
      ),
    );
  }
}
