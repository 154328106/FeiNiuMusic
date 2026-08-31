import 'package:flutter/material.dart';

import '../../app/services/netease/netease_playback_service.dart';
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
  const SourceFeedPage({super.key, required this.kind, required this.title});

  final HomeFeed kind;
  final String title;

  @override
  State<SourceFeedPage> createState() => _SourceFeedPageState();
}

class _SourceFeedPageState extends State<SourceFeedPage> {
  final _player = PlayerService.instance;

  List<SongEntity> _songs = const [];
  bool _loading = true;

  MusicSource get _source => MusicSourceRegistry.instance.current.value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // 这里要完整列表，不是首页那份 10 首的预览。
    final songs = await _source.fullFeed(widget.kind, limit: 500);
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  /// 起播。网易云队列先筛掉取不到地址的歌，否则会卡在第一首不动。
  Future<void> _play(int index) async {
    var queue = _songs;
    var start = index;
    if (_source.id == 'netease') {
      final tapped = _songs[index];
      queue = await NetEasePlaybackService.instance.prepareQueue(_songs);
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
      body: _buildBody(scheme),
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
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
