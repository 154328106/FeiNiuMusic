import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../components/index.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';
import '../../app/theme/app_styles.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

class RecentPlaybackPage extends StatefulWidget {
  const RecentPlaybackPage({super.key});

  @override
  State<RecentPlaybackPage> createState() => _RecentPlaybackPageState();
}

class _RecentPlaybackPageState extends State<RecentPlaybackPage>
    with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _allSongs = createSignal<List<SongEntity>>([]);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _loading = createSignal(true);
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _applyFilter() {
    final all = _allSongs.value;
    if (_searchQuery.isEmpty) {
      _songs.value = all;
    } else {
      final q = _searchQuery.toLowerCase();
      _songs.value = all.where((s) {
        return s.title.toLowerCase().contains(q) ||
            s.artistDisplayName.toLowerCase().contains(q);
      }).toList();
    }
  }

  Future<void> _loadHistory() async {
    _loading.value = true;
    try {
      final pageData = await _api.getPlayHistory(page: 1, size: 100);
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (mounted) {
        _allSongs.value = songs;
        _applyFilter();
      }
    } catch (e) {
      debugPrint('[RecentPlaybackPage] load error: $e');
    }
    if (mounted) _loading.value = false;
  }

  void _playSong(int index) {
    final songs = _songs.value;
    if (songs.isEmpty) return;
    _player.playQueue(songs, index);
  }

  /// 长按歌曲 → 弹出与歌曲页同款的长按面板，并附带「移出最近播放」。
  void _showSongDetail(SongEntity song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        onOpenArtist: (name) {
          final artistGuid = song.firstArtistGuid;
          if (artistGuid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  artistName: name,
                  artistGuid: artistGuid,
                ),
              ),
            );
          }
        },
        onOpenAlbum: (name) {
          final guid = song.albumGuid;
          if (guid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AlbumDetailPage(
                  albumName: name,
                  albumGuid: guid,
                ),
              ),
            );
          }
        },
        extraActions: [
          AppListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: '移出最近播放',
            titleColor: Theme.of(context).colorScheme.error,
            onTap: () async {
              try {
                await _api.deletePlayHistory([song.id]);
                if (!mounted) return;
                final updated = List<SongEntity>.from(_allSongs.value)
                  ..removeWhere((s) => s.id == song.id);
                _allSongs.value = updated;
                _applyFilter();
                AppToast.show(context, '已移出最近播放');
              } catch (e) {
                if (!mounted) return;
                AppToast.show(context, '操作失败', type: ToastType.error);
              }
              if (!mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 2 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        appBar: AppTopBar(
          title: '最近播放',
          showBackButton: false,
          leading: useBottomNavigation
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
              onPressed: () {
                setState(() {
                  _searchVisible = !_searchVisible;
                  if (!_searchVisible) {
                    _searchController.clear();
                    _searchQuery = '';
                    _applyFilter();
                  }
                });
              },
            ),
          ],
        ),
        body: Column(
          children: [
            if (_searchVisible)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) {
                    setState(() => _searchQuery = v);
                    _applyFilter();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索最近播放...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                              _applyFilter();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: theme.appPanelColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            Expanded(
              child: Watch.builder(
                builder: (context) {
                  if (_loading.value) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final songs = _songs.value;
                  if (songs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.history_rounded,
                            size: 64,
                            color: scheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '还没有播放记录',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: _loadHistory,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Row(
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => _player.playShuffle(_songs.value),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.shuffle_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              Text(
                                '共 ${_allSongs.value.length} 首',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 160),
                            itemCount: songs.length,
                            itemBuilder: (context, index) {
                              final song = songs[index];
                              return InkWell(
                                onTap: () => _playSong(index),
                                onLongPress: () => _showSongDetail(song),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    children: [
                                      ArtworkWidget(
                                        song: song,
                                        size: 48,
                                        borderRadius: 8,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              song.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
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
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
