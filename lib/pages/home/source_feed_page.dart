import 'package:flutter/material.dart';

import '../../app/services/player_service.dart';
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// 通用的「某个源的某条歌曲流」列表页。
///
/// 飞牛的收藏页 / 最近播放页带分页、多选、删除历史等一整套飞牛专属能力，
/// 换源后照搬不过来（网易云是一次性返回整张歌单，没有同样的分页语义）。
/// 与其把那两个页面改成半通用，不如给非飞牛的源一个干净的只读列表 ——
/// 先让「点收藏能看到收藏」成立，再谈功能对齐。
class SourceFeedPage extends StatefulWidget {
  const SourceFeedPage({
    super.key,
    this.kind,
    this.playlistId,
    this.loader,
    required this.title,
  }) : assert(
         kind != null || playlistId != null || loader != null,
         'kind / playlistId / loader 至少给一个',
       );

  /// 首页那几条流之一。给了 [playlistId] 或 [loader] 时为 null。
  final HomeFeed? kind;

  /// 歌单 id（带源前缀）。给了它就展示这个歌单，而不是某条流。
  final String? playlistId;

  /// 直接给一个取歌函数 —— 「酷狗每日推荐 / 私人漫游」这种既不是歌单、
  /// 也不在 [HomeFeed] 枚举里的一次性列表走这条。
  ///
  /// 优先级最高：给了它就不看 [playlistId] / [kind]。
  final Future<List<SongEntity>> Function()? loader;

  final String title;

  @override
  State<SourceFeedPage> createState() => _SourceFeedPageState();
}

class _SourceFeedPageState extends State<SourceFeedPage> {
  final _player = PlayerService.instance;

  List<SongEntity> _songs = const [];
  bool _loading = true;

  /// 正在为起播做准备（网易云要先批量问播放地址）。
  ///
  /// 没有这个标记时，点一首要等好几秒才出声，期间界面毫无反应，看着就像
  /// 「点了没用」，于是用户会连点好几下 —— 每一下又各自发一轮请求，更慢。
  bool _preparing = false;

  /// 后台每批为多少首歌准备地址。
  ///
  /// 只用在**起播之后**的后台填充里 —— 同步那一步只解你点的那一首。
  /// 批次小一点，下一首就能更早可用（每首过公益源约 1 秒，10 首约 10 秒
  /// 就能追加一批）；批次大了第一次追加会来得太晚。
  static const int _backgroundBatch = 10;

  MusicSource get _source => MusicSourceRegistry.instance.current.value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // 这里要完整列表，不是首页那份预览。
    final loader = widget.loader;
    final playlistId = widget.playlistId;
    final List<SongEntity> songs;
    if (loader != null) {
      songs = await loader();
    } else if (playlistId != null) {
      songs = await _source.playlistSongs(playlistId);
    } else {
      songs = await _source.fullFeed(widget.kind!, limit: 500);
    }
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  /// 起播。网易云队列先筛掉取不到地址的歌，否则会卡在第一首不动。
  Future<void> _play(int index) async {
    if (_preparing) return; // 准备中再点没有意义，反而各发一轮请求
    if (_source.id == 'feiniu') {
      // 飞牛是自己的 NAS，地址是确定的，不需要预解析。
      await _player.playQueue(_songs, index);
      return;
    }

    // **只同步解「你点的这一首」，解完立刻起播，其余交给后台。**
    //
    // 原来这里同步解 25 首（_prepareWindow）。而没有会员的账号，官方给的是
    // 试听片段，等于 25 首全要过一遍公益源、每首约 1 秒 —— 点一下要等二十
    // 多秒才出声，用户的原话是「点完半天没反应，还以为死机了」。
    //
    // 能这么改的前提是：**播放器本来就逐首按需解地址**
    // （`PlayerService._resolvePlayableUri`，网易云/QQ/酷狗都有分支，注释里
    // 还写着「地址有时效，不能用 song.uri 里存的那份」）。所以那一整轮批量
    // 解析从来不是播放的必要条件，它只是个预筛 —— 提前剔掉没地址的歌，
    // 免得队列卡住。点中的这首同步解掉，卡第一首的问题就已经解决了；
    // 后面那些真没地址的，播到了由播放器跳过，代价远小于每次都等二十秒。
    final tapped = _songs[index];
    setState(() => _preparing = true);
    List<SongEntity> head;
    try {
      head = await _source.prepareQueue([tapped]);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (!mounted) return;
    if (head.isEmpty) {
      AppToast.showGlobal('这首取不到播放地址', type: ToastType.error);
      return;
    }

    // 后台把队列填到上限。用 playQueueFilledToLimit 而不是 queueExtender：
    // 后者只在「切歌且队列快播完」时触发，**且随机模式下压根不触发**
    // （见 PlayerService 里那个 playbackMode != shuffle 的判断）——
    // 只解一首再靠它续接，在随机模式下会卡死在一首歌上。
    // 后台填充和队尾续接共用这一个游标。
    //
    // 不需要加锁或标志位：取批次和推进游标之间没有 await，所以两个调用方
    // 不可能拿到同一批，也不会跳过某一批 —— 最多是追加顺序交错一点。
    // （第一版在这儿加了个 `filling` 标志，结果是死锁：后台填满上限后就
    // 不再调 fetchMore，标志永远不会被清掉，续接器被永久堵死，歌单比上限
    // 长时播到 80 首就断了。）
    var offset = index + 1;
    Future<List<SongEntity>> nextBatch() async {
      if (offset >= _songs.length) return const <SongEntity>[];
      final next = _songs.skip(offset).take(_backgroundBatch).toList();
      offset += _backgroundBatch;
      return _source.prepareQueue(next);
    }

    await _player.playQueueFilledToLimit(
      head,
      0,
      fetchMore: (_) => nextBatch(),
    );
    // 必须挂在上面那句**之后**：playQueue 内部第一件事就是把 queueExtender 清空。
    _player.queueExtender = nextBatch;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: AppTopBar(
        title: widget.title,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(scheme),
          // 准备播放地址时顶一条细进度条：点下去立刻有反馈。
          if (_preparing)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_songs.isEmpty) {
      return Center(
        child: Text(
          '${widget.title}暂无内容',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        AppPageScaffold.scrollableBottomPadding(context),
      ),
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final song = _songs[index];
        return AppContentRow(
          isLast: index == _songs.length - 1,
          horizontalInset: 10,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: ArtworkWidget(song: song, size: 48, borderRadius: 8),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (song.isVip) const VipBadge(),
              ],
            ),
            subtitle: Text(
              song.artistDisplayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _play(index),
          ),
        );
      },
    );
  }
}
