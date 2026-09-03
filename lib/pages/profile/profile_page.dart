import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
import '../../app/router/app_router.dart' show AppRoutes;
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/services/kugou/kugou_api_client.dart';
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
              // 「听歌统计」原来独占一个「更多」分组 —— 一个大面板只装一行，
              // 空得明显，和上面两个深色分组叠在一起就是三坨一样的块。改成
              // 首页那种渐变卡：有颜色、有分量，也不用再为一项开一个分组。
              const _StatsCard(),
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
      accent: Theme.of(context).colorScheme.secondary,
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
          accent: Theme.of(context).colorScheme.primary,
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

  /// 酷狗账号弹窗里那段说明。
  ///
  /// 「会员」和「设备标识」两行是有用的诊断：会员决定官方给不给地址，设备
  /// 没注册则一律不给 —— 这两样都不该靠翻日志才知道。
  static String _kugouAccountDetail(KugouAuth auth) {
    final lines = <String>[
      '已登录${auth.nickname.isEmpty ? '' : '：${auth.nickname}'}',
      '会员：${auth.isVip ? 'VIP${auth.vipType}' : '无'}',
      '设备标识：${auth.hasDfid ? '已注册' : '未注册'}',
      '',
      if (!auth.hasDfid) ...[
        '设备没注册时，会员曲的官方地址一律拿不到，只能靠第三方音源兜。'
            '可以点「重注册设备」再试一次。',
        '',
      ],
      '退出后仍可用推荐、榜单和搜索，但会员曲和云端歌单拿不到。',
    ];
    return lines.join('\n');
  }

  /// 酷狗扫码登录。登录后能听会员曲，还能同步云端歌单和「我喜欢」。
  Future<void> _onLoginKugou(
    BuildContext context,
    MusicSourceRegistry registry,
  ) async {
    final auth = KugouAuth.instance;
    if (auth.isLoggedIn.value) {
      // 设备注册状态直接写在这儿。它决定会员曲能不能拿到官方地址，出问题
      // 时不该让人翻日志去猜 —— 没注册就给一个当场重试的按钮。
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('酷狗音乐账号'),
          content: Text(_kugouAccountDetail(auth)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('取消'),
            ),
            if (!auth.hasDfid)
              TextButton(
                onPressed: () => Navigator.pop(context, 'device'),
                child: const Text('重注册设备'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'logout'),
              child: const Text('退出登录'),
            ),
          ],
        ),
      );
      if (action == 'device') {
        await KugouApiClient.instance.registerDevice();
        AppToast.showGlobal(
          KugouAuth.instance.hasDfid ? '设备注册成功' : '设备注册失败，看日志',
          type: KugouAuth.instance.hasDfid ? ToastType.success : ToastType.error,
        );
        KugouPlaybackService.instance.clear();
        registry.notifyContentChanged();
        return;
      }
      if (action != 'logout') return;
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

/// 听歌统计入口卡。
///
/// 视觉语言对齐首页的功能卡（渐变底 + 圆形图标底座），让「我的」这一页
/// 不至于从上到下全是同一种深色面板。
class _StatsCard extends StatelessWidget {
  const _StatsCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.tertiary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.pushNamed(context, AppRoutes.listeningStats),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: 0.16),
                accent.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: appUnitBorder(context, accent: accent),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.18),
                ),
                alignment: Alignment.center,
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/icon/stats.png',
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.bar_chart_rounded,
                    color: accent,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '听歌统计',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '本地播放数据概览',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
