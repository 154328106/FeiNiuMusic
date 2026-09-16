import 'package:flutter/material.dart';

import '../../app/services/player_service.dart';
import '../../app/services/source/music_source.dart';
import '../../app/services/source/music_source_registry.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// 通用的「搜当前源」页面。
///
/// 飞牛和网易云各有自己的搜索页（飞牛那套吃 FeiNiuTrack 强类型，网易云那页
/// 还带扫码登录入口），这里给后加的源用 —— 只做「搜出来、点了能播」，
/// 数据全走 [MusicSource.search]，加一个新源不用再抄一遍页面。
class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key, this.embedded = false});

  /// 作为底部导航的「搜索」页使用时置 true：套 [AppPageScaffold]、挂底栏。
  final bool embedded;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final PlayerService _player = PlayerService.instance;

  List<SongEntity> _results = const [];
  bool _searching = false;
  bool _preparing = false;

  /// 每次搜索自增：只有最后一次发起的搜索允许写回结果，避免快速改关键词时
  /// 先发的慢请求盖掉后发的快请求。
  int _searchToken = 0;

  MusicSource get _source => MusicSourceRegistry.instance.current.value;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    final token = ++_searchToken;
    setState(() => _searching = true);
    final songs = await _source.search(keyword, limit: 50);
    if (!mounted || token != _searchToken) return;
    setState(() {
      _results = songs;
      _searching = false;
    });
  }

  /// 后台每批为多少首歌预取地址。只用在起播之后。
  static const int _backgroundBatch = 10;

  Future<void> _play(int index) async {
    if (_preparing) return;
    final tapped = _results[index];
    setState(() => _preparing = true);
    List<SongEntity> queue;
    try {
      // **只同步解点中的那一首。** 原来是 `prepareQueue(_results)` ——
      // 把**整个搜索结果**一次全解，连窗口都没有。没有会员的账号等于
      // 几十首全过公益源、每首约 1 秒，点一下要等半分钟。
      // 播放器本来就逐首按需解地址，这轮批量只是预筛（同 songs_page）。
      queue = await _source.prepareQueue([tapped]);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (!mounted) return;
    if (queue.isEmpty) {
      AppToast.showGlobal('这首取不到播放地址', type: ToastType.error);
      return;
    }
    var offset = index + 1;
    Future<List<SongEntity>> nextBatch() async {
      if (offset >= _results.length) return const <SongEntity>[];
      final next = _results.skip(offset).take(_backgroundBatch).toList();
      offset += _backgroundBatch;
      return _source.prepareQueue(next);
    }

    await _player.playQueueFilledToLimit(
      queue,
      0,
      fetchMore: (_) => nextBatch(),
    );
    // 续接器要挂在上面那句之后：playQueue 内部会先清空它。
    _player.queueExtender = nextBatch;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _runSearch(),
            decoration: InputDecoration(
              hintText: '搜索${_source.label}',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _runSearch,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (_preparing) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildBody(theme)),
      ],
    );

    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: Text('搜索 · ${_source.label}')),
        body: body,
      );
    }
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        appBar: AppTopBar(
          title: '搜索 · ${_source.label}',
          showBackButton: !useBottomNavigation,
        ),
        bottomNavIndex: useBottomNavigation ? 2 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        body: body,
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '搜索${_source.label}曲库',
          style: TextStyle(color: theme.hintColor),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: widget.embedded
            ? AppPageScaffold.scrollableBottomPadding(context)
            : 0,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final song = _results[index];
        return ListTile(
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
        );
      },
    );
  }
}
