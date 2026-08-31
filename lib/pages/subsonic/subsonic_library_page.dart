import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/player_service.dart';
import '../../app/services/subsonic/subsonic_api_client.dart';
import '../../app/services/subsonic/subsonic_server.dart';
import '../../app/services/subsonic/subsonic_track_mapper.dart';
import '../../app/state/settings_platform_state.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// Subsonic 音乐库：搜索 + 最新专辑 + 收藏 + 随机。
///
/// 与网易云那页同理，做成**独立页面**而不是塞进飞牛的库页 —— 飞牛那套页面
/// 从上到下吃 `FeiNiuTrack` 强类型，塞第二个数据源要动几十个文件。
class SubsonicLibraryPage extends StatefulWidget {
  const SubsonicLibraryPage({super.key});

  @override
  State<SubsonicLibraryPage> createState() => _SubsonicLibraryPageState();
}

enum _SubsonicTab { search, starred, random }

class _SubsonicLibraryPageState extends State<SubsonicLibraryPage> {
  final _controller = TextEditingController();
  final _api = SubsonicApiClient.instance;
  final _player = PlayerService.instance;

  _SubsonicTab _tab = _SubsonicTab.starred;
  List<SongEntity> _songs = const [];
  bool _loading = false;
  String? _error;

  /// 每次请求自增：只有最后一次发起的请求允许写回结果。
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await SubsonicServerStore.instance.load();
    if (!mounted) return;
    if (!_api.isConfigured) {
      setState(() => _error = '尚未配置服务器');
      return;
    }
    await _load(_SubsonicTab.starred);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load(_SubsonicTab tab, {String? keyword}) async {
    final token = ++_token;
    setState(() {
      _tab = tab;
      _loading = true;
      _error = null;
    });
    try {
      final raw = switch (tab) {
        _SubsonicTab.search => await _api.searchSongs(keyword ?? ''),
        _SubsonicTab.starred => await _api.starredSongs(),
        _SubsonicTab.random => await _api.randomSongs(),
      };
      if (!mounted || token != _token) return;
      setState(() {
        _songs = SubsonicTrackMapper.toSongEntities(raw);
        _loading = false;
      });
    } on SubsonicApiException catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 切回飞牛：门控随即重建 —— 飞牛已登录就进主界面，没登录就回登录页。
  ///
  /// 只改「当前平台」，不清 Subsonic 服务器配置：下次再切回来不用重填。
  Future<void> _switchPlatform() async {
    await AppPlatformSettings.setActive(AppPlatform.feiniu);
  }

  void _runSearch() {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    _load(_SubsonicTab.search, keyword: keyword);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: AppTopBar(
        title: 'Subsonic',
        actions: [
          IconButton(
            tooltip: '服务器设置',
            icon: const Icon(Icons.dns_rounded),
            onPressed: () async {
              await Navigator.pushNamed(context, AppRoutes.subsonicServer);
              if (!mounted) return;
              _bootstrap();
            },
          ),
          // 这页是 Subsonic 会话的**根页面**（门控直接渲染它），没有可 pop 的
          // 上一页。不给出口就成了死路 —— iOS 上更是连系统返回键都没有。
          IconButton(
            tooltip: '切换平台',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: _switchPlatform,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                hintText: '搜索曲库',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _tabChip('收藏', _SubsonicTab.starred),
                const SizedBox(width: 8),
                _tabChip('随机', _SubsonicTab.random),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _tabChip(String label, _SubsonicTab tab) {
    final selected = _tab == tab;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => _load(tab),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: scheme.outline),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () =>
                    Navigator.pushNamed(context, AppRoutes.subsonicServer),
                child: const Text('去设置服务器'),
              ),
            ],
          ),
        ),
      );
    }
    if (_songs.isEmpty) {
      return Center(
        child: Text('没有内容', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: AppPageScaffold.scrollableBottomPadding(context),
      ),
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final song = _songs[index];
        return AppContentRow(
          isLast: index == _songs.length - 1,
          horizontalInset: 10,
          child: ListTile(
            leading: ArtworkWidget(song: song, size: 48, borderRadius: 8),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                song.artistDisplayName,
                song.albumDisplayName,
              ].where((s) => s.isNotEmpty && s != '未知专辑').join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _player.playQueue(_songs, index),
          ),
        );
      },
    );
  }
}
