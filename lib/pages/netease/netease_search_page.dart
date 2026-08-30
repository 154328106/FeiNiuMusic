import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/netease/netease_api_client.dart';
import '../../app/services/netease/netease_models.dart';
import '../../app/services/netease/netease_playback_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';

/// 网易云搜索页。
///
/// 刻意做成**独立入口**，不复用飞牛的搜索页：飞牛那套页面从上到下吃
/// `FeiNiuTrack` 强类型（guid / coverId / FeiNiuAlbum），塞进第二个数据源
/// 要动 30 多个文件。等这条链路验证稳了再谈两边合流。
class NetEaseSearchPage extends StatefulWidget {
  const NetEaseSearchPage({super.key});

  @override
  State<NetEaseSearchPage> createState() => _NetEaseSearchPageState();
}

class _NetEaseSearchPageState extends State<NetEaseSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final NetEaseApiClient _api = NetEaseApiClient.instance;
  final PlayerService _player = PlayerService.instance;

  List<NetEaseSong> _results = const [];
  bool _searching = false;
  String? _error;

  /// 每次搜索自增：只有最后一次发起的搜索允许写回结果，避免快速改关键词时
  /// 先发的慢请求覆盖后发的快请求。
  int _searchToken = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }

    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final songs = await _api.searchSongs(keyword, limit: 50);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = songs;
        _searching = false;
      });
    } on NetEaseApiException catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = e.message;
        _searching = false;
      });
    }
  }

  /// 点歌起播：把整个搜索结果作为播放队列，从点中的那首开始。
  ///
  /// 播放地址不在这里解析——`PlayerService` 会在真正取播放源时调
  /// [NetEasePlaybackService.resolveStreamUrl]，那才是地址新鲜的时刻。
  Future<void> _playAt(int index) async {
    final queue = <SongEntity>[
      for (final song in _results) NetEasePlaybackService.toSongEntity(song),
    ];
    await _player.playQueue(queue, index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网易云音乐')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                hintText: '搜索歌曲',
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
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: theme.disabledColor),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _runSearch,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('搜索网易云曲库', style: TextStyle(color: theme.hintColor)),
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final song = _results[index];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: song.coverUrl == null
                ? Container(width: 48, height: 48, color: theme.cardColor)
                : CachedNetworkImage(
                    imageUrl: song.coverUrl!,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 48,
                      height: 48,
                      color: theme.cardColor,
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 48,
                      height: 48,
                      color: theme.cardColor,
                    ),
                  ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (song.isVip)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.primary),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    'VIP',
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            [song.artists, song.album].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _playAt(index),
        );
      },
    );
  }
}
