import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/router/app_router.dart' show AppRoutes;
import '../../app/services/source/feiniu_source.dart';
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
              // 账号管理卡已去掉：飞牛的登录/管理整合到「音乐来源」的飞牛那栏
              // （没连写「登录」、连上写「管理」，点进去就是原账号管理页）。
              const _MusicSourceSection(),
              const SizedBox(height: 16),
              // 「主题外观」已搬到设置页最上方。这里原来的位置改放「听歌统计」，
              // 带一个和「音乐来源」同款、同字号的「| 听歌统计」分组标题。
              const _StatsSection(),
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
        final accent = Theme.of(context).colorScheme.primary;
        // 不再套 AppSettingSection：那个组件会把 children 包进一层描边面板，
        // 而这里三张卡自己就有底色和描边，套进去就是双层框。只借它的标题行样式。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 14,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '音乐来源',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: accent.withValues(alpha: 0.95),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < MusicSourceRegistry.all.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _SourceBar(
                source: MusicSourceRegistry.all[i],
                selected: identical(MusicSourceRegistry.all[i], current),
                onTap: () =>
                    _onTap(context, MusicSourceRegistry.all[i], registry),
                onLogin: switch (MusicSourceRegistry.all[i].id) {
                  'feiniu' => () => _onFeiniu(context),
                  'netease' => () => _onLogin(context, registry),
                  'qq' => () => _onLoginQQ(context, registry),
                  'kugou' => () => _onLoginKugou(context, registry),
                  _ => null,
                },
              ),
            ],
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

  /// 飞牛：进账号管理页（原「账号管理」入口整合到这里）。没连是「登录」，
  /// 连上是「管理」——都进同一个页面添加/切换账号。
  Future<void> _onFeiniu(BuildContext context) async {
    await Navigator.pushNamed(context, AppRoutes.accounts);
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

/// 音乐来源的横条卡。
///
/// 原来是设置项列表里的三行 AppSettingTile，和「切换数据来源」这件事的分量
/// 不太相称 —— 它其实是这个 App 最常动的开关之一。改成三张带强调色的横条，
/// 视觉语言和同页的 [_StatsCard]、首页的快捷卡片一致。
class _SourceBar extends StatelessWidget {
  final MusicSource source;
  final bool selected;
  final VoidCallback onTap;

  /// 需要账号的源给一个单独的登录入口；为 null 表示这个源不谈登录。
  final VoidCallback? onLogin;

  const _SourceBar({
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
      FeiniuSource() => src.isAvailable,
      NetEaseSource() => src.isLoggedIn,
      QQSource() => QQAuth.instance.isLoggedIn.value,
      KugouSource() => KugouAuth.instance.isLoggedIn.value,
      _ => true,
    };
    // 飞牛那栏登录后写「管理」（进账号管理），其余源写「账号」。
    final loggedInLabel = src is FeiniuSource ? '管理' : '账号';
    final accent = source.accent;
    return Container(
      height: 72,
      decoration: BoxDecoration(
        // 选中的那张底色和描边都加重一档，一眼能看出在用哪个源。
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: selected
              ? [accent.withValues(alpha: 0.30), accent.withValues(alpha: 0.11)]
              : [accent.withValues(alpha: 0.14), accent.withValues(alpha: 0.05)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accent.withValues(alpha: selected ? 0.60 : 0.20),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      source.assetIcon,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      // 资源缺失时退回图标，不至于整张卡报红。
                      errorBuilder: (_, _, _) =>
                          Icon(source.icon, size: 30, color: accent),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          source.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // 只说「在用 / 能切」。登录与否右边的按钮已经写着了。
                        Text(
                          selected ? '当前使用中' : '点击切换',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onLogin != null)
                    TextButton(
                      onPressed: onLogin,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: Text(loggedIn ? loggedInLabel : '登录'),
                    ),
                  // 勾位固定占宽：不占的话选中那张的按钮会被勾挤走，
                  // 三张卡的「账号 / 登录」就对不齐了。
                  SizedBox(
                    width: 26,
                    child: selected
                        ? Icon(
                            Icons.check_circle_rounded,
                            size: 20,
                            color: accent,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 听歌统计入口卡。
///
/// 视觉语言对齐首页的功能卡（渐变底 + 圆形图标底座），让「我的」这一页
/// 不至于从上到下全是同一种深色面板。
/// 「听歌统计」分组：和「音乐来源」同款、同字号的「| 听歌统计」标题 + 渐变卡。
class _StatsSection extends StatelessWidget {
  const _StatsSection();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.tertiary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '听歌统计',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: accent.withValues(alpha: 0.95),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const _StatsCard(),
      ],
    );
  }
}

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
              // 和「音乐来源」里酷狗/飞牛图标同款：40×40 圆角方块、无外圈，
              // 这样位置和文字跟上面几行对齐。
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/icon/TG.png',
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.bar_chart_rounded,
                    color: accent,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(width: 12),
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
