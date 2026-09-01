import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/netease/netease_playback_service.dart';
import '../../app/services/player_service.dart';
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/services/source/netease_source.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../app/tv/tv_layout.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/primary_tab_refresh_mixin.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../library/playlists_page.dart';
import '../search/search_page.dart';
import '../songs/song_detail_sheet.dart';
import '../songs/songs_page.dart';
import 'source_feed_page.dart';
import 'source_playlists_page.dart';
import 'widgets/home_cover_carousel.dart';
import 'widgets/home_hero_banner.dart';
import 'widgets/home_large_layout.dart';
import 'widgets/home_quick_actions.dart';
import 'widgets/home_section_header.dart';
import 'widgets/home_shortcut_menu.dart';

/// 首页缓存
class _HomeCacheData {
  final List<SongEntity>? favorites;
  final List<SongEntity>? recentSongs;
  final List<FeiNiuAlbum>? recentAlbums;
  final List<FeiNiuPlaylist>? playlists;
  final List<SongEntity>? recentTracks;

  _HomeCacheData({
    this.favorites,
    this.recentSongs,
    this.recentAlbums,
    this.playlists,
    this.recentTracks,
  });

  bool get isEmpty =>
      (favorites == null || favorites!.isEmpty) &&
      (recentSongs == null || recentSongs!.isEmpty) &&
      (recentAlbums == null || recentAlbums!.isEmpty) &&
      (playlists == null || playlists!.isEmpty) &&
      (recentTracks == null || recentTracks!.isEmpty);

  Map<String, dynamic> toJson() => {
    'favorites': favorites?.map((s) => s.toMap()).toList(),
    'recentSongs': recentSongs?.map((s) => s.toMap()).toList(),
    'recentAlbums': recentAlbums?.map((a) => a.toJson()).toList(),
    'playlists': playlists?.map((p) => p.toJson()).toList(),
    'recentTracks': recentTracks?.map((s) => s.toMap()).toList(),
  };

  static _HomeCacheData fromJson(Map<String, dynamic> json) => _HomeCacheData(
    favorites: (json['favorites'] as List?)
        ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
        .toList(),
    recentSongs: (json['recentSongs'] as List?)
        ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
        .toList(),
    recentAlbums: (json['recentAlbums'] as List?)
        ?.map((e) => FeiNiuAlbum.fromJson(e as Map<String, dynamic>))
        .toList(),
    playlists: (json['playlists'] as List?)
        ?.map((e) => FeiNiuPlaylist.fromJson(e as Map<String, dynamic>))
        .toList(),
    recentTracks: (json['recentTracks'] as List?)
        ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
        .toList(),
  );
}

/// 首页播放数据源：决定点播放时按队列上限请求哪个 API 填充完整队列。
enum _HomePlaySource { favorites, recentHistory, recentTracks }

/// 飞牛首页 — 云端音乐仪表板
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SignalsMixin, PrimaryTabRefreshMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  /// 最近一次由首页卡片发起播放的来源，以及当时送进播放器的队列 id 集合。
  ///
  /// 漫游大图自动轮播的定时器。
  Timer? _roamAutoTimer;
  bool _roamAutoBusy = false;

  /// 轮播间隔。每一跳都是一次 roam-next 网络请求，太密既费流量也没意义。
  static const Duration _roamAutoInterval = Duration(minutes: 2);

  late final _loading = createSignal(true);
  late final _roamSong = createSignal<SongEntity?>(null);
  late final _roamId = createSignal<String?>(null);
  late final _roamQueue = createSignal<List<SongEntity>>([]);
  late final _favoriteSongs = createSignal<List<SongEntity>>([]);
  late final _recentSongs = createSignal<List<SongEntity>>([]);
  late final _recentAlbums = createSignal<List<FeiNiuAlbum>>([]);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);
  late final _recentTracks = createSignal<List<SongEntity>>([]);

  /// 「最新歌曲」的候选池：接口拉一大把，首页只露 [_latestVisible] 首，
  /// 每 [_latestShuffleInterval] 从池子里重新抽一批 —— 只拉 4 首的话
  /// 首页永远是同样那几首。换得太勤反而晃眼，两分钟一次。
  List<SongEntity> _latestPool = const [];
  static const int _latestVisible = 4;
  static const int _latestPoolSize = 40;
  static const Duration _latestShuffleInterval = Duration(minutes: 2);
  Timer? _latestShuffleTimer;
  final Random _random = Random();
  late final _isRefreshing = createSignal(false);

  /// 首页顶部大图的标签：飞牛是「漫游 · 随心听」，网易云是「私人 FM」等。
  late final _heroLabel = createSignal<String>('漫游 · 随心听');

  /// 当前音乐源。首页所有数据都从它取，不再直接调飞牛接口。
  MusicSource get _source => MusicSourceRegistry.instance.current.value;

  @override
  void initState() {
    super.initState();
    debugPrint('[HomePage#$_instanceId] initState');
    _loadAll();
    _maybeShowTvEdgeHint();
    _roamAutoTimer = Timer.periodic(_roamAutoInterval, (_) => _autoRoamTick());
    _latestShuffleTimer = Timer.periodic(
      _latestShuffleInterval,
      (_) => _shuffleLatestTick(),
    );
    MusicSourceRegistry.instance.current.addListener(_onSourceChanged);
    // 登录 / 登出后源没换但内容变了，也要重拉。
    MusicSourceRegistry.instance.revision.addListener(_onSourceChanged);
  }

  /// 换源后整页重新拉取。清掉播放来源标记，否则卡片按钮会残留上一个源的状态。
  void _onSourceChanged() {
    if (!mounted) return;
    _latestPool = const [];
    // 漫游状态要立刻清掉。留着的话大图上还是上一个源的那首，用户这时候
    // 点播放，放出来的就是上一个源的歌 —— 切到网易云却放了飞牛的曲子。
    _roamSong.value = null;
    _roamQueue.value = const [];
    _roamId.value = null;
    _loading.value = true;
    unawaited(_loadAll(forceRefresh: true));
  }

  @override
  void dispose() {
    debugPrint('[HomePage#$_instanceId] dispose');
    // 漫游扩展器挂在全局播放器上，不摘掉的话这个已经死了的首页还会继续被
    // 回调，往正在播的队列里追加它那条漫游链的歌。
    if (_player.queueExtender == _roamQueueExtender) {
      _player.queueExtender = null;
    }
    _roamAutoTimer?.cancel();
    _latestShuffleTimer?.cancel();
    MusicSourceRegistry.instance.current.removeListener(_onSourceChanged);
    MusicSourceRegistry.instance.revision.removeListener(_onSourceChanged);
    super.dispose();
  }

  /// 漫游大图自动换一首。
  ///
  /// 几种情况要跳过，否则纯属白跑网络请求、甚至干扰用户：
  /// - 首页不在前台（切到别的 tab、或播放页盖在上面）；
  /// - 正在播这首漫游歌 —— 换掉的话大图按钮会从「暂停」跳回「播放」，
  ///   等于在用户眼皮底下把他正在听的那首换走了；
  /// - 上一跳还没回来。
  void _autoRoamTick() {
    if (!mounted || _roamAutoBusy) return;
    if (primaryNavigationShellActive && primaryNavigationIndex.value != 0) {
      return;
    }
    if (AppLayoutSettings.playerRouteActive.value) return;
    if (_heroIsPlaying) return;
    _roamAutoBusy = true;
    unawaited(
      _refreshRoam(silent: true).whenComplete(() => _roamAutoBusy = false),
    );
  }

  /// TV 首次启动：展示「按右键打开播放页」提示（只一次，会话级别持久化）。
  void _maybeShowTvEdgeHint() {
    if (!AppLayoutSettings.tvMode.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await AppLayoutSettings.consumeTvEdgeHint()) return;
      if (!mounted) return;
      AppToast.show(context, '遥控器：按 ← 打开侧栏，按 → 打开播放页');
    });
  }

  @override
  int get primaryTabIndex => 0;

  @override
  Future<void> onPrimaryTabActivated() async {
    if (mounted) await _loadAll();
  }

  /// 活着的 HomePage 实例序号。
  ///
  /// 日志里每一行都成对出现，重入闸和 tab 激活那两处都排除掉之后，剩下的
  /// 解释只有「同时存在两个 State」。把序号打进日志，一眼就能看出是同一个
  /// 实例跑了两遍，还是两个实例各跑一遍。
  static int _instanceSeq = 0;
  late final int _instanceId = ++_instanceSeq;

  /// 整页刷新的重入闸。
  ///
  /// 触发口有四个：initState、tab 激活、下拉刷新、换源。换源那条尤其容易
  /// 连响两次（`setCurrent` 动 current，登录回调又动 revision），两趟完整
  /// 刷新并发跑，日志里所有行成对出现、请求量翻倍，界面还被连着覆盖两次。
  bool _loadInFlight = false;

  Future<void> _loadAll({bool forceRefresh = false}) async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    try {
      var force = forceRefresh;
      // 换源正好撞上另一趟刷新时，光靠上面的闸会把新源那次请求丢掉，首页
      // 就停在旧源的内容上。所以刷完再对一次源：变了就补一趟。
      for (var round = 0; round < 3; round++) {
        final loadedSource = _source.id;
        await _runLoadAll(forceRefresh: force);
        if (!mounted || _source.id == loadedSource) break;
        force = true;
      }
    } finally {
      _loadInFlight = false;
    }
  }

  Future<void> _runLoadAll({bool forceRefresh = false}) async {
    const homeCacheScope = 'home';
    final homeCacheKey = 'dashboard_${_source.id}';

    // 缓存永久保留（读取 ignoreTtl，TTL 不淘汰），但只用于快速渲染：
    // 命中后立即展示，同时继续在后台异步刷新数据，完成后覆盖缓存。
    //
    // 只在**首次加载**（_loading 还是 true）读它。从别的页面回到首页时内存
    // 里已经是同一批数据，再套一遍缓存等于把每个列表换成一份反序列化出来的
    // 新对象，列表整体重建、封面控件跟着重新挂载 —— 就是「回首页后最新歌曲
    // 的封面闪一下重刷」。
    if (!forceRefresh && _loading.value) {
      final cachedJson = await ApiCacheManager.instance.getPersisted(
        homeCacheScope,
        homeCacheKey,
      );
      if (cachedJson != null && mounted) {
        try {
          final cached = _HomeCacheData.fromJson(
            jsonDecode(cachedJson) as Map<String, dynamic>,
          );
          if (!mounted) return;
          if (cached.favorites != null) {
            _favoriteSongs.value = cached.favorites!;
          }
          if (cached.recentSongs != null) {
            _recentSongs.value = cached.recentSongs!;
          }
          if (cached.recentAlbums != null) {
            _recentAlbums.value = cached.recentAlbums!;
          }
          if (cached.playlists != null) {
            _playlists.value = cached.playlists!;
          }
          if (cached.recentTracks != null) {
            _recentTracks.value = cached.recentTracks!;
          }
          _loading.value = false;
          _preloadHomeCovers();
        } catch (e, stack) {
          // 缓存解析失败则忽略，但记录到调试日志便于排查
          debugPrint('[HomePage] cache parse error: $e\n$stack');
        }
      }
    }

    // 后台异步刷新最新数据（缓存渲染后继续执行），完成后写回缓存
    _isRefreshing.value = !_loading.value; // 非首次加载才显示右上角转圈
    await Future.wait([
      _loadRoam(force: forceRefresh),
      _loadFavorites(),
      _loadRecentHistory(),
      _loadRecentAlbums(),
      _loadPlaylists(),
      _loadRecentTracks(),
    ]);
    if (mounted) {
      _loading.value = false;
      _isRefreshing.value = false;
      _preloadHomeCovers();
      debugPrint(
        '[HomePage#$_instanceId] loadAll done: '
        'favorites=${_favoriteSongs.value.length} '
        'history=${_recentSongs.value.length} '
        'albums=${_recentAlbums.value.length} '
        'playlists=${_playlists.value.length} '
        'tracks=${_recentTracks.value.length}',
      );
      // 写回缓存（永久保留，下次启动仍用于渲染）
      try {
        final data = _HomeCacheData(
          favorites: _favoriteSongs.value,
          recentSongs: _recentSongs.value,
          recentAlbums: _recentAlbums.value,
          playlists: _playlists.value,
          recentTracks: _recentTracks.value,
        );
        await ApiCacheManager.instance.set(
          scope: homeCacheScope,
          key: homeCacheKey,
          jsonData: jsonEncode(data.toJson()),
        );
      } catch (e, stack) {
        debugPrint('[HomePage] cache write error: $e\n$stack');
      }
    }
  }

  void _preloadHomeCovers() {
    if (!mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();

    // 把 coverId 变成真正会被请求的地址，规则必须和 ArtworkWidget 一致。
    //
    // 非飞牛的源（网易云）在 coverId 里存的就是公网直链。之前这里一律套
    // api.coverUrl()，拼出 `…/static/cover?coverId=http%3A//p4.music…`
    // 这种 NAS 一律 400 的地址：预热的是错地址，真正要显示的那批一张都没
    // 预热到 —— 换网易云后首页封面每次都得现下。返回值第二项表示是不是
    // 公网直链，直链不能带飞牛的鉴权头。
    (String, bool) coverOf(String coverId, {int? updatedAt}) {
      if (coverId.startsWith('http')) return (coverId, true);
      return (
        api.coverUrl(
          coverId,
          size: FeiNiuApiClient.coverRequestSize,
          updatedAt: updatedAt,
        ),
        false,
      );
    }

    // 预加载首页所有可见封面（最多 40 张）
    final covers = <(String, bool)>[
      // Hero Banner 主视觉 — 大尺寸首帧
      if (_heroSong != null &&
          _heroSong!.coverId != null &&
          _heroSong!.coverId!.isNotEmpty)
        coverOf(_heroSong!.coverId!, updatedAt: _heroSong!.updatedAt),
      // 收藏歌曲封面
      for (final s in _favoriteSongs.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          coverOf(s.coverId!, updatedAt: s.updatedAt),
      // 最近播放封面
      for (final s in _recentSongs.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          coverOf(s.coverId!, updatedAt: s.updatedAt),
      // 最近添加歌曲封面
      for (final s in _recentTracks.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          coverOf(s.coverId!, updatedAt: s.updatedAt),
      // 专辑封面 — FeiNiuAlbum 无 updatedAt
      for (final a in _recentAlbums.value.take(10))
        if (a.coverId != null && a.coverId!.isNotEmpty) coverOf(a.coverId!),
      // 歌单封面
      for (final p in _playlists.value.take(10))
        if (p.coverId != null && p.coverId!.isNotEmpty)
          coverOf(p.coverId!, updatedAt: p.updatedAt),
    ];
    for (final (url, isRemote) in covers) {
      if (!mounted) break;
      try {
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(
              url,
              headers: isRemote ? null : headers,
            ),
            context,
          ),
        );
      } catch (_) {
        // 外壳可能正在卸载：deactivate 到 unmount 之间的窗口内 State.mounted
        // 仍为 true（_element 尚未置空），但元素已失活，precacheImage 内部的
        // DefaultAssetBundle.of(context) 会抛 "Looking up a deactivated
        // widget's ancestor"。封面预加载是尽力而为的缓存预热，跳过即可。
      }
    }
  }

  Future<void> _loadRoam({bool force = false}) async {
    // 大图已经有内容就不重取。从别的页面回首页会走一次整页刷新，那时候把
    // 大图换掉等于「一切页面回来歌就变了」。换源和下拉刷新才强制重取，
    // 常规的自动换一首交给 _autoRoamTick。
    if (!force && _roamSong.value != null) return;
    final hero = await _source.hero();
    if (!mounted) return;
    if (hero == null) {
      _roamSong.value = null;
      _roamQueue.value = const [];
      _roamId.value = null;
      return;
    }
    _roamId.value = hero.chainId;
    _roamSong.value = hero.song;
    _roamQueue.value = hero.queue;
    _heroLabel.value = hero.label;
  }

  /// 漫游刷新：换一首漫游歌曲（不打断播放）。
  ///
  /// 用 roam-next 拉取下一首，更新 Banner 显示、_roamId 与 _roamQueue。
  /// 不触碰正在播放的队列——历史问题：播放中刷新把新歌 insertNext 进播放
  /// 队列会重建当前 run，打断正在播放的音乐。需要播放新歌时由用户点 Banner
  /// 触发 [_extendAndPlay]（以当前显示歌为队首重开队列）。
  Future<void> _refreshRoam({bool silent = false}) async {
    final hero = await _source.refreshHero();
    if (hero == null || !mounted) {
      if (!silent && mounted) {
        AppToast.showGlobal('获取推荐歌曲失败', type: ToastType.error);
      }
      return;
    }
    _roamId.value = hero.chainId;
    _roamSong.value = hero.song;
    _heroLabel.value = hero.label;
    // 队列以「当前显示的这首」为队首：点播放时播的就是大图上这首。
    _roamQueue.value = hero.queue;
  }

  /// 两批歌是不是同一批（按 id 逐个比）。
  ///
  /// 每次刷新拿到的都是**新构造**的 SongEntity 列表，直接赋值必定触发重建，
  /// 列表行连带封面控件一起重新挂载，已经缓存好的图也会先闪一下占位图 ——
  /// 「从别的页面回首页，最新歌曲的封面重刷一遍」就是这么来的。后台刷新
  /// 绝大多数时候结果和屏幕上的一模一样，这时候什么都不做才对。
  static bool _sameSongs(List<SongEntity> a, List<SongEntity> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _loadFavorites() async {
    // 首页只展示前几首；点播放时再按队列上限拉完整列表。
    final songs = await _source.feed(HomeFeed.favorites);
    if (mounted && !_sameSongs(_favoriteSongs.value, songs)) {
      _favoriteSongs.value = songs;
    }
  }

  Future<void> _loadRecentHistory() async {
    final songs = await _source.feed(HomeFeed.recentPlayed);
    if (mounted && !_sameSongs(_recentSongs.value, songs)) {
      _recentSongs.value = songs;
    }
  }

  Future<void> _loadRecentAlbums() async {
    // 专辑目前只有飞牛实现（大屏布局在用），其它源直接跳过。
    if (_source.id != 'feiniu') {
      if (mounted) _recentAlbums.value = const [];
      return;
    }
    try {
      final pageData = await _api.getAlbumList(
        page: 1,
        size: 10,
        sort: 'newTrackAddedAt,desc',
      );
      if (mounted) _recentAlbums.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] albums error: $e\n$stack');
    }
  }

  Future<void> _loadPlaylists() async {
    if (_source.id != 'feiniu') {
      // 歌单区块只做飞牛。用同一套封面轮播渲染网易云歌单试过了，混在
      // 首页里不好看，去掉；真要做得单开一页而不是塞成一排。
      if (mounted) _playlists.value = const [];
      return;
    }
    try {
      final pageData = await _api.getPlaylistList(page: 1, size: 10);
      if (mounted) _playlists.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] playlists error: $e\n$stack');
    }
  }

  Future<void> _loadRecentTracks() async {
    final songs = await _source.feed(
      HomeFeed.latestSongs,
      limit: _latestPoolSize,
    );
    if (!mounted) return;
    _latestPool = songs;
    // 正在展示的那批还在池子里就别动 —— 每次回首页都换一批同样是闪。
    // 换歌交给 30 秒的定时器。
    final poolIds = {for (final s in songs) s.id};
    final current = _recentTracks.value;
    final stillValid =
        current.isNotEmpty && current.every((s) => poolIds.contains(s.id));
    if (!stillValid) _pickLatestSample();
  }

  /// 从候选池里随机抽 [_latestVisible] 首铺到首页。
  void _pickLatestSample() {
    if (!mounted) return;
    final pool = _latestPool;
    if (pool.length <= _latestVisible) {
      if (!_sameSongs(_recentTracks.value, pool)) _recentTracks.value = pool;
      return;
    }
    // 抽到和当前一模一样时再试两次，免得「换一批」看着像没动。
    var sample = const <SongEntity>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      sample = (List<SongEntity>.of(pool)..shuffle(
        _random,
      )).take(_latestVisible).toList();
      if (!_sameSongs(_recentTracks.value, sample)) break;
    }
    if (!_sameSongs(_recentTracks.value, sample)) _recentTracks.value = sample;
  }

  /// 定时换一批。首页不在前台时不动，免得用户回来时内容已经变了。
  void _shuffleLatestTick() {
    if (!mounted || _latestPool.length <= _latestVisible) return;
    if (primaryNavigationShellActive && primaryNavigationIndex.value != 0) {
      return;
    }
    if (AppLayoutSettings.playerRouteActive.value) return;
    _pickLatestSample();
  }

  /// 长按歌曲 → 弹出与歌曲页同款的长按面板
  void _showSongDetail(SongEntity song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        onUpdated: (_) => _loadAll(forceRefresh: true),
      ),
    );
  }

  /// 漫游播放 — 播放首页当前显示的漫游歌曲，播完后自动下一首随机。
  ///
  /// 用 [_heroSong] 兜底：漫游歌未加载时（接口失败/卡住），Banner 显示的是
  /// 收藏/最近兜底歌，点击播放必须与其一致，否则「显示歌 ≠ 实际播放」。
  void _playRoam() {
    final song = _heroSong;
    if (song == null) {
      debugPrint('[HomePage] playRoam: no song available');
      return;
    }
    unawaited(_extendAndPlay(song));
  }

  /// 漫游队列扩展器 — 每次队列快播完时调用 roam-next 获取新歌曲追加
  /// 队列快播完时追加：飞牛走 roam-next，其它源取下一批推荐。
  Future<List<SongEntity>> _roamQueueExtender() async {
    final hero = await _source.refreshHero();
    if (hero == null) return const [];
    if (mounted) _roamId.value = hero.chainId;
    return hero.queue;
  }

  Future<void> _extendAndPlay(SongEntity first) async {
    try {
      // 直接用 banner 当前漫游链：_loadRoam 已用 getRoamStart 拿到
      // current（显示歌）+ next，并存于 _roamQueue / _roamId。用这套队列
      // 播放既保证播的是 banner 显示的歌，又保证队列、roamId 同一条链，
      // 点下一曲不会新开队列。
      var songs = _roamQueue.value;
      if (songs.isEmpty) {
        songs = [first];
      }
      final roamId = _roamId.value;
      if (mounted) {
        // mode: shuffle + roamId 直接传入 playQueue：playQueue 内部会清空
        // 再恢复 roamId，消除「返回后手动恢复」的时序窗口，确保点下一曲时
        // 走 roam-next 追加分支而非 getRoamStart 新开队列。
        debugPrint(
          '[HomePage] extendAndPlay queue=${songs.map((s) => s.title).join(',')} '
          'roamId=$roamId',
        );
        await _player.playQueue(
          songs,
          0,
          mode: PlaybackMode.shuffle,
          roamChainId: roamId,
        );
        debugPrint('[HomePage] extendAndPlay done, roamId=$roamId');
        // 后续走 PlayerService 内部漫游扩展逻辑（随机模式下播完/切歌追加下一首）
        _player.queueExtender = _roamQueueExtender;
      }
    } catch (e) {
      debugPrint('[HomePage] roam play error: $e');
      await _player.playQueue(
        [first],
        0,
        mode: PlaybackMode.shuffle,
        roamChainId: _roamId.value,
      );
      _player.queueExtender = _roamQueueExtender;
    }
  }

  void _openAlbumDetail(FeiNiuAlbum album) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => AlbumDetailPage(albumName: album.name, albumGuid: album.guid),
      ),
    );
  }

  void _openPlaylistDetail(FeiNiuPlaylist playlist) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => PlaylistDetailPage(playlistId: playlist.guid),
      ),
    );
  }

  /// 漫游歌曲为空时，用第一首收藏/最近歌曲兜底，保证 Hero 始终有内容
  SongEntity? get _heroSong {
    final roam = _roamSong.value;
    if (roam != null) return roam;
    if (_favoriteSongs.value.isNotEmpty) return _favoriteSongs.value.first;
    if (_recentSongs.value.isNotEmpty) return _recentSongs.value.first;
    if (_recentTracks.value.isNotEmpty) return _recentTracks.value.first;
    return null;
  }

  void _openPlaylistsPage() {
    Navigator.of(context).pushNamed(AppRoutes.playlists);
  }

  /// 四个快捷入口。飞牛是曲库维度（歌单/歌手/专辑/风格），网易云换成它
  /// 自己有的那几样，没有的一律不放 —— 摆个点进去是空的入口更糟。
  List<HomeShortcutItem> _shortcutItems() {
    if (_source.id != 'netease') {
      return [
        HomeShortcutItem(
          icon: Icons.queue_music_rounded,
          label: '歌单',
          accent: const Color(0xFF3B82F6),
          onTap: _openPlaylistsPage,
        ),
        HomeShortcutItem(
          icon: Icons.people_rounded,
          label: '歌手',
          accent: const Color(0xFF14B8A6),
          onTap: _openArtistsPage,
        ),
        HomeShortcutItem(
          icon: Icons.album_rounded,
          label: '专辑',
          accent: const Color(0xFFA855F7),
          onTap: _openAlbumsPage,
        ),
        HomeShortcutItem(
          icon: Icons.music_video_rounded,
          label: '风格',
          accent: const Color(0xFFF97316),
          onTap: _openGenresPage,
        ),
      ];
    }
    final source = NetEaseSource.instance;
    return [
      HomeShortcutItem(
        icon: Icons.wb_sunny_rounded,
        label: '每日推荐',
        accent: const Color(0xFFF97316),
        onTap: () => _playNetEaseList('每日推荐', source.dailyRecommend),
      ),
      HomeShortcutItem(
        icon: Icons.radio_rounded,
        label: '私人FM',
        accent: const Color(0xFF14B8A6),
        onTap: () => _playNetEaseList('私人 FM', source.personalFm),
      ),
      HomeShortcutItem(
        icon: Icons.leaderboard_rounded,
        label: '排行榜',
        accent: const Color(0xFFEC4899),
        onTap: () => _openSourcePlaylists('排行榜', source.toplists),
      ),
      HomeShortcutItem(
        icon: Icons.queue_music_rounded,
        label: '歌单',
        accent: const Color(0xFF3B82F6),
        onTap: () => _openSourcePlaylists(
          '歌单',
          () => source.playlists(limit: 50),
          emptyHint: '登录网易云后这里是你的歌单；未登录时给的是推荐歌单。',
        ),
      ),
    ];
  }

  void _openSourcePlaylists(
    String title,
    Future<List<SourcePlaylist>> Function() loader, {
    String? emptyHint,
  }) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => SourcePlaylistsPage(
          title: title,
          loader: loader,
          emptyHint: emptyHint,
        ),
      ),
    );
  }

  /// 拉一批网易云的歌直接开播（每日推荐 / 私人 FM）。
  ///
  /// 这两样没有对应的列表页 —— 点了就是要听，先筛掉拿不到地址的再起播，
  /// 否则队列会卡在第一首不动。
  Future<void> _playNetEaseList(
    String label,
    Future<List<SongEntity>> Function() loader,
  ) async {
    final songs = await loader();
    if (!mounted) return;
    if (songs.isEmpty) {
      AppToast.showGlobal('$label暂无内容', type: ToastType.error);
      return;
    }
    final queue = await NetEasePlaybackService.instance.prepareQueue(songs);
    if (!mounted) return;
    if (queue.isEmpty) {
      AppToast.showGlobal('$label里的歌都取不到播放地址', type: ToastType.error);
      return;
    }
    _player.playQueue(queue, 0);
  }

  /// 右上角搜索 → 综合搜索页。搜的是当前源：网易云走网易云的搜索页。
  void _openSearch() {
    if (_source.id == 'netease') {
      Navigator.pushNamed(context, AppRoutes.neteaseSearch);
      return;
    }
    Navigator.pushNamed(
      context,
      AppRoutes.search,
      arguments: SearchCategory.all,
    );
  }

  void _openSongsPage() {
    // 从首页「最新歌曲」进入：一次性按创建时间降序（不回写偏好，仅本次有效）
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => const SongsPage(
          initialSortKey: 'duration',
          initialAscending: false,
        ),
      ),
    );
  }

  void _openArtistsPage() {
    Navigator.of(context).pushNamed(AppRoutes.artists);
  }

  void _openAlbumsPage() {
    Navigator.of(context).pushNamed(AppRoutes.albums);
  }

  void _openGenresPage() {
    Navigator.of(context).pushNamed(AppRoutes.genres);
  }

  /// 飞牛走原有的收藏页 / 最近播放页（分页、多选、删历史都在那里）；
  /// 其它源没有对应能力，给一个通用的只读列表页。
  void _openFeedPage(HomeFeed kind, String title, String feiniuRoute) {
    if (_source.id == 'feiniu') {
      Navigator.of(context).pushNamed(feiniuRoute);
      return;
    }
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => SourceFeedPage(kind: kind, title: title),
      ),
    );
  }

  void _openRecentPage() =>
      _openFeedPage(HomeFeed.recentPlayed, '最近播放', AppRoutes.recent);

  void _openFavoritePage() =>
      _openFeedPage(HomeFeed.favorites, '收藏', AppRoutes.favorites);

  /// 直接播放一个列表（收藏/最近播放）。列表为空时退回漫游随机播放。
  ///
  /// [source] 指定首页数据源：列表只是 10 首预览，播放时按队列上限
  /// 请求完整列表填充队列，而不是只播预览的 10 首。
  /// hero 大图按钮：正在放这首 hero 歌就切换播放/暂停，否则起播漫游。
  void _togglePlayRoam() {
    final hero = _heroSong;
    if (hero != null && _player.currentSongSignal.value?.id == hero.id) {
      unawaited(_player.togglePlayPause());
      return;
    }
    _playRoam();
  }

  /// hero 大图当前是否正在播放。
  bool get _heroIsPlaying {
    final hero = _heroSong;
    if (hero == null) return false;
    if (!_player.isPlayingSignal.value) return false;
    return _player.currentSongSignal.value?.id == hero.id;
  }

  void _playFromList(List<SongEntity> songs, _HomePlaySource source) {
    if (songs.isEmpty) {
      _playRoam();
      return;
    }
    unawaited(_playListWithFullFetch(songs, source, playIndex: 0));
  }

  /// 从首页歌曲行播放：队列用完整列表（若已拉过完整列表则直接复用）。
  void _playHomeSong(
    SongEntity song,
    List<SongEntity> preview,
    _HomePlaySource source,
  ) {
    unawaited(_playListWithFullFetch(preview, source, song: song));
  }

  /// 按队列长度上限请求完整列表填充队列后播放。
  ///
  /// 首页只展示前 10 首（轻量加载），点播放时才拉完整列表做队列：
  /// - [source] 决定走哪个 API（收藏/最近/最新歌曲）
  /// - 已有完整列表缓存（[fullCache]）时直接复用，避免重复请求
  Future<void> _playListWithFullFetch(
    List<SongEntity> preview,
    _HomePlaySource source, {
    SongEntity? song,
    int playIndex = 0,
    List<SongEntity>? fullCache,
  }) async {
    var queue = fullCache ?? preview;
    if (fullCache == null) {
      try {
        final limit = AppPlaybackQueueSettings.maxQueueLength.value;
        final full = await _fetchFullSource(source, limit);
        if (full.isNotEmpty) queue = full;
      } catch (e) {
        debugPrint('[HomePage] fetch full queue error: $e');
      }
    }
    if (!mounted) return;
    // 网易云队列里可能夹着下架/无版权的歌，取不到地址会让整队卡住不动，
    // 起播前先批量筛一遍（一次请求）。
    if (_source.id == 'netease') {
      queue = await NetEasePlaybackService.instance.prepareQueue(queue);
      if (!mounted || queue.isEmpty) return;
    }
    if (song != null) {
      final idx = queue.indexWhere((s) => s.id == song.id);
      _player.playQueue(queue, idx >= 0 ? idx : 0);
    } else {
      final idx = playIndex.clamp(0, queue.length - 1);
      _player.playQueue(queue, idx);
    }
  }

  /// 请求某一数据源的完整列表（按队列上限）。
  Future<List<SongEntity>> _fetchFullSource(
    _HomePlaySource source,
    int limit,
  ) async {
    final kind = switch (source) {
      _HomePlaySource.favorites => HomeFeed.favorites,
      _HomePlaySource.recentHistory => HomeFeed.recentPlayed,
      _HomePlaySource.recentTracks => HomeFeed.latestSongs,
    };
    return _source.fullFeed(kind, limit: limit);
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '首页',
          showBackButton: false,
          centerTitle: false,
          isRefreshing: _isRefreshing.value,
          leading: useBottomNavigation || AppLayoutSettings.tvMode.value
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          actions: [
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search_rounded),
              onPressed: _openSearch,
            ),
          ],
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        body: ValueListenableBuilder<bool>(
          valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
          builder: (context, effectiveTabletMode, _) {
            return _buildHomeBody(context, effectiveTabletMode);
          },
        ),
      ),
    );
  }

  /// 首页主体：平板/TV/Windows 用大屏五模块布局，手机端保持原滚动布局。
  Widget _buildHomeBody(BuildContext context, bool effectiveTabletMode) {
    return Watch.builder(
      builder: (context) {
        if (_loading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        final heroSong = _heroSong;
        // 平板 / TV / Windows：大屏布局
        if (effectiveTabletMode) {
          return RefreshIndicator(
            onRefresh: () => _loadAll(forceRefresh: true),
            child: HomeLargeLayout(
              heroSong: heroSong,
              onPlayRoam: _togglePlayRoam,
              heroIsPlaying: _heroIsPlaying,
              onRefreshRoam: _refreshRoam,
              shortcutItems: [
                HomeShortcutItem(
                  icon: Icons.queue_music_rounded,
                  label: '歌单',
                  accent: const Color(0xFF3B82F6),
                  onTap: _openPlaylistsPage,
                ),
                HomeShortcutItem(
                  icon: Icons.people_rounded,
                  label: '歌手',
                  accent: const Color(0xFF14B8A6),
                  onTap: _openArtistsPage,
                ),
                HomeShortcutItem(
                  icon: Icons.album_rounded,
                  label: '专辑',
                  accent: const Color(0xFFA855F7),
                  onTap: _openAlbumsPage,
                ),
                HomeShortcutItem(
                  icon: Icons.music_video_rounded,
                  label: '风格',
                  accent: const Color(0xFFF97316),
                  onTap: _openGenresPage,
                ),
              ],
              recentSongs: _recentSongs.value,
              onPlayRecent: () => _playFromList(
                _recentSongs.value,
                _HomePlaySource.recentHistory,
              ),
              onOpenRecent: _openRecentPage,
              onTapRecent: (song) => _playHomeSong(
                song,
                _recentSongs.value,
                _HomePlaySource.recentHistory,
              ),
              onLongPressRecent: _showSongDetail,
              playlists: _playlists.value,
              onOpenPlaylists: _openPlaylistsPage,
              onTapPlaylist: _openPlaylistDetail,
              recentAlbums: _recentAlbums.value,
              onOpenAlbums: () {
                Navigator.of(context).pushNamed(AppRoutes.albums);
              },
              onTapAlbum: _openAlbumDetail,
              recentTracks: _recentTracks.value,
              favoriteSongs: _favoriteSongs.value,
              onOpenSongs: _openSongsPage,
              onOpenFavorite: _openFavoritePage,
              onTapTrack: (song) => _playHomeSong(
                song,
                _recentTracks.value,
                _HomePlaySource.recentTracks,
              ),
              onLongPressTrack: _showSongDetail,
              onTapFavorite: (song) => _playHomeSong(
                song,
                _favoriteSongs.value,
                _HomePlaySource.favorites,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => _loadAll(forceRefresh: true),
          child: ListView(
            padding: AppLayoutSettings.tvMode.value
                ? TvLayout.pagePadding()
                : const EdgeInsets.fromLTRB(20, 8, 20, 160),
            children: [
              // 1. Hero Banner — 漫游/今日推荐，封面是绝对主角
              if (heroSong != null)
                // 自动轮播换歌时做交叉淡入淡出，避免大图硬切。
                AppContentFrame(
                  child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 420),
                  child: HomeHeroBanner(
                    key: ValueKey(heroSong.id),
                    song: heroSong,
                    label: _heroLabel.value,
                    onPlay: _togglePlayRoam,
                    isPlaying: _heroIsPlaying,
                    onRefresh: _refreshRoam,
                  ),
                ),
                ),

              if (heroSong != null) const SizedBox(height: 16),

              // 1.5 快捷菜单（4×1）。四个入口跟着当前源走 —— 歌手/专辑/风格
              // 都是飞牛曲库的概念，换到网易云还摆在那儿点进去必然是空的。
              HomeShortcutMenu(items: _shortcutItems()),

              const SizedBox(height: 16),

              // 2. 功能入口 — 收藏 / 最近播放。只是入口，点进去再挑歌；
              // 卡片上的直接播放按钮去掉了。
              HomeQuickActions(
                actions: [
                  HomeQuickAction(
                    icon: Icons.history_rounded,
                    title: '最近播放',
                    subtitle: '接着上次听',
                    accent: const Color(0xFF14B8A6),
                    onTap: _openRecentPage,
                  ),
                  HomeQuickAction(
                    icon: Icons.favorite_rounded,
                    title: '收藏',
                    subtitle: '我的最爱',
                    accent: const Color(0xFFEC4899),
                    onTap: _openFavoritePage,
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // 3. 我的歌单 — 横向封面轮播（尺寸小于专辑）
              // 歌单区块暂时只支持飞牛：详情页与缓存仍是飞牛强类型。
              // 换源后显示飞牛歌单会是错的，先隐藏。
              if (_source.id == 'feiniu' && _playlists.value.isNotEmpty) ...[
                HomeSectionHeader(title: '我的歌单', onViewAll: _openPlaylistsPage),
                AppContentFrame(
                  child: HomeCoverCarousel(
                  coverSize: AppLayoutSettings.tvMode.value ? 140 : 100,
                  borderRadius: 14,
                  centerText: true,
                  items: [
                    for (final p in _playlists.value)
                      HomeCoverItem(
                        coverId: p.coverId,
                        updatedAt: p.updatedAt,
                        title: p.name,
                        // 歌单没有数量副标题，空串不占行，避免卡片下方留白
                        subtitle: '',
                        onTap: () => _openPlaylistDetail(p),
                      ),
                  ],
                ),
                ),
                const SizedBox(height: 16),
              ],

              // 4. 最新歌曲 — 紧凑竖排行列表
              if (_recentTracks.value.isNotEmpty) ...[
                HomeSectionHeader(title: '最新歌曲', onViewAll: _openSongsPage),
                AppContentFrame(
                  // 行自带卡片，卡片模式下别再套外框。
                  wrapsRows: true,
                  child: _CompactSongList(
                    songs: _recentTracks.value,
                    onTap: (song) => _playHomeSong(
                      song,
                      _recentTracks.value,
                      _HomePlaySource.recentTracks,
                    ),
                    onLongPress: _showSongDetail,
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // 「最新专辑」区块已移除：首页上方的功能入口里已有「专辑」，
              // 底部再放一次重复。_recentAlbums 仍由大屏布局
              // （HomeLargeLayout）使用，故保留数据加载。

              // 空状态
              // 判空要把所有区块都算上。原来只看收藏 / 最近播放 / 专辑，
              // 网易云下这三样常常是空的（收藏没登录、专辑压根没有），
              // 于是明明大图和最新歌曲都有内容，底下还挂着「还没有数据」。
              if (_favoriteSongs.value.isEmpty &&
                  _recentSongs.value.isEmpty &&
                  _recentAlbums.value.isEmpty &&
                  _recentTracks.value.isEmpty &&
                  _playlists.value.isEmpty &&
                  heroSong == null)
                const _HomeEmptyState(text: '还没有数据，下拉刷新试试'),
            ],
          ),
        );
      },
    );
  }
}

// MARK: - 紧凑歌曲列表

/// 最新歌曲 — 紧凑竖排行列表（封面 44 + 两行文字 + 播放按钮）
class _CompactSongList extends StatelessWidget {
  final List<SongEntity> songs;
  final ValueChanged<SongEntity> onTap;
  final ValueChanged<SongEntity>? onLongPress;

  const _CompactSongList({
    required this.songs,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTv = AppLayoutSettings.tvMode.value;
    final artworkSize = isTv ? 56.0 : 44.0;
    // 固定 4 首：5 首时最后一行会被底部迷你播放条 + 导航栏盖住。
    final displaySongs = songs.take(4).toList();
    return Column(
      children: List.generate(displaySongs.length, (i) {
        final song = displaySongs[i];
        final isLast = i == displaySongs.length - 1;
        return Padding(
          // 「逐行卡片」样式自带行间距，这里就不要再加 6，否则两处间距叠加。
          padding: EdgeInsets.only(
            bottom:
                (isLast ||
                    AppBackgroundSettings.contentFrameStyle.value ==
                        AppContentFrameStyle.cards)
                ? 0
                : 6,
          ),
          child: AppContentRow(
            isLast: isLast,
            child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onTap(song),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(song),
              child: Padding(
                // TV 端加大行高与封面，方便遥控器聚焦。
                padding: EdgeInsets.symmetric(
                  horizontal: isTv ? 12 : 6,
                  vertical: isTv ? 8 : 5,
                ),
                child: Row(
                  children: [
                    ArtworkWidget(
                      song: song,
                      size: artworkSize,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (song.isVip) const VipBadge(),
                            ],
                          ),
                          const SizedBox(height: 1),
                          Text(
                            song.artistDisplayName,
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
                    Icon(
                      Icons.play_circle_outline_rounded,
                      size: 28,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
        );
      }),
    );
  }
}

class _HomeEmptyState extends StatelessWidget {
  final String text;

  const _HomeEmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
