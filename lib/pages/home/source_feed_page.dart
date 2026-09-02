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
    required this.title,
  }) : assert(kind != null || playlistId != null, 'kind 与 playlistId 至少给一个');

  /// 首页那几条流之一。给了 [playlistId] 时为 null。
  final HomeFeed? kind;

  /// 歌单 id（带源前缀）。给了它就展示这个歌单，而不是某条流。
  final String? playlistId;

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

  /// 一次最多为多少首歌准备地址。
  ///
  /// 整张歌单几百首全问一遍要好几秒，而且后面那些等真播到了早过期了。
  /// 从点中的位置往后取一段就够，播完这段会自然续。
  static const int _prepareWindow = 25;

  MusicSource get _source => MusicSourceRegistry.instance.current.value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // 这里要完整列表，不是首页那份预览。
    final playlistId = widget.playlistId;
    final songs = playlistId != null
        ? await _source.playlistSongs(playlistId)
        : await _source.fullFeed(widget.kind!, limit: 500);
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  /// 起播。网易云队列先筛掉取不到地址的歌，否则会卡在第一首不动。
  Future<void> _play(int index) async {
    if (_preparing) return; // 准备中再点没有意义，反而各发一轮请求
    var queue = _songs;
    var start = index;
    if (_source.id != 'feiniu') {
      final tapped = _songs[index];
      // 从点中的位置往后取一段，别把整张歌单都问一遍。
      final window = _songs.skip(index).take(_prepareWindow).toList();
      setState(() => _preparing = true);
      try {
        queue = await _source.prepareQueue(window);
      } finally {
        if (mounted) setState(() => _preparing = false);
      }
      if (!mounted || queue.isEmpty) return;
      // 筛完索引会变，按歌曲 id 重新定位；点中的那首若被筛掉就从头播。
      final moved = queue.indexWhere((s) => s.id == tapped.id);
      start = moved >= 0 ? moved : 0;
    }
    await _player.playQueue(queue, start);
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
