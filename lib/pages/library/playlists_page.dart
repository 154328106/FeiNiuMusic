import 'dart:async';

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/playlist_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/router/app_page_route.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/deferred_page_init_mixin.dart';
import '../../app/theme/app_styles.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage>
    with SignalsMixin, DeferredPageInitMixin {
  static const String _prefsSortMode = 'playlists_sort_mode_v1';
  static const String _prefsSortAscending = 'playlists_sort_ascending_v1';

  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);
  late final _sortMode = createSignal('name');
  late final _ascending = createSignal(true);
  late final _isRefreshing = createSignal(false);
  late final _filteredPlaylists = createSignal<List<FeiNiuPlaylist>>([]);
  List<FeiNiuPlaylist> _allPlaylists = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  void _preloadCovers(List<FeiNiuPlaylist> items, {int count = 20}) {
    if (items.isEmpty || !mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    for (final p in items.take(count)) {
      if (p.coverId != null && p.coverId!.isNotEmpty) {
        final url = api.coverUrl(p.coverId!, size: 120, updatedAt: p.updatedAt);
        unawaited(precacheImage(
          CachedNetworkImageProvider(url, headers: headers),
          context,
        ));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    scheduleDeferredInit();
  }

  @override
  Future<void> runDeferredInit() async {
    await _init();
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var mode = (prefs.getString(_prefsSortMode) ?? 'name').trim();
    if (mode.isEmpty) mode = 'name';
    final asc = prefs.getBool(_prefsSortAscending) ?? true;
    _sortMode.value = mode;
    _ascending.value = asc;
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSortMode, _sortMode.value);
    await prefs.setBool(_prefsSortAscending, _ascending.value);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    const cacheKey = 'all';

    Future<List<FeiNiuPlaylist>> fetch() async {
      return await _service.getPlaylistList();
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final playlists = await fetch();
        if (!mounted) return;
        _allPlaylists = playlists;
        _applySortFromBase();
        _preloadCovers(playlists);
        _loading.value = false;
        await ApiCacheManager.instance.set(
          scope: 'playlist_list',
          key: cacheKey,
          jsonData: jsonEncode(playlists.map((p) => p.toJson()).toList()),
        );
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    _isRefreshing.value = true;
    try {
      void onData(List<FeiNiuPlaylist>? data) {
        if (mounted) {
          if (data != null) {
            _allPlaylists = data;
            _applySortFromBase();
            _preloadCovers(data);
            _loading.value = false;
          }
          _isRefreshing.value = false; // 后台刷新完成
        }
      }

      final cached = await ApiCacheManager.instance.cacheThenNetwork(
        scope: 'playlist_list',
        key: cacheKey,
        fetch: fetch,
        fromJson: (json) => (jsonDecode(json) as List)
            .map((e) => FeiNiuPlaylist.fromJson(e as Map<String, dynamic>))
            .toList(),
        toJson: (data) => jsonEncode(data.map((p) => p.toJson()).toList()),
        fetchCallback: onData,
      );

      if (cached != null) {
        // 缓存命中 → 全屏转圈消失，右上角转圈保持直到后台刷新结束
        if (mounted) {
          _allPlaylists = cached;
          _applySortFromBase();
          _preloadCovers(cached);
          _loading.value = false;
        }
      }
    } catch (e) {
      debugPrint('[PlaylistsPage] load error: $e');
      if (mounted) {
        _isRefreshing.value = false;
        _loading.value = false;
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _applySortFromBase() {
    final playlists = List<FeiNiuPlaylist>.from(_allPlaylists);

    if (_sortMode.value == 'custom') {
      _playlists.value = playlists;
      _applySearch();
      return;
    }

    int compare(FeiNiuPlaylist a, FeiNiuPlaylist b) {
      switch (_sortMode.value) {
        case 'name':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'count':
          return a.trackCount.compareTo(b.trackCount);
        case 'recent':
        default:
          return a.createdAt.compareTo(b.createdAt);
      }
    }

    playlists.sort(compare);
    if (!_ascending.value) {
      _playlists.value = playlists.reversed.toList();
    } else {
      _playlists.value = playlists;
    }
    _applySearch();
  }

  void _applySearch() {
    if (_searchQuery.isEmpty) {
      _filteredPlaylists.value = _playlists.value;
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredPlaylists.value = _playlists.value.where((p) {
        return p.name.toLowerCase().contains(q);
      }).toList();
    }
  }

  Future<void> _createPlaylist() async {
    await _showPlaylistNameDialog(
      context,
      title: '新建歌单',
      initial: '',
      confirmText: '创建',
      fallbackName: '新建歌单',
      onSubmit: (name) async {
        await _service.createPlaylist(name);
        if (!mounted) return;
        AppToast.show(context, '已创建歌单');
        await _load();
      },
    );
  }

  Future<void> _renamePlaylist(FeiNiuPlaylist playlist) async {
    await _showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      initial: playlist.name,
      confirmText: '保存',
      fallbackName: null,
      onSubmit: (name) async {
        await _service.editPlaylist(guid: playlist.guid, name: name);
        if (!mounted) return;
        AppToast.show(context, '已重命名');
        await _load();
      },
    );
  }

  Future<void> _deletePlaylist(FeiNiuPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '删除歌单',
        contentText: '确定删除「${playlist.name}」吗？',
        isDestructive: true,
        onConfirm: () {},
      ),
    );
    if (confirmed != true) return;
    await _service.deletePlaylist(playlist.guid);
    if (!mounted) return;
    AppToast.show(context, '已删除');
    await _load();
  }

  void _showPlaylistSheet(FeiNiuPlaylist playlist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return AppSheetPanel(
          title: playlist.name,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppListTile(
                leading: const Icon(Icons.edit_rounded),
                title: '重命名',
                onTap: () {
                  Navigator.of(context).pop();
                  _renamePlaylist(playlist);
                },
              ),
              AppListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: '删除',
                titleColor: Colors.red,
                onTap: () {
                  Navigator.of(context).pop();
                  _deletePlaylist(playlist);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return SortSheet(
          title: '歌单排序',
          options: const [
            SortOption(
              key: 'recent',
              label: '创建时间',
              icon: Icons.schedule_rounded,
            ),
            SortOption(
              key: 'name',
              label: '名称',
              icon: Icons.sort_by_alpha_rounded,
            ),
            SortOption(
              key: 'count',
              label: '歌曲数量',
              icon: Icons.queue_music_rounded,
            ),
          ],
          currentKey: _sortMode.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortMode.value = value;
            _applySortFromBase();
            _savePrefs();
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _applySortFromBase();
            _savePrefs();
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '歌单',
          isRefreshing: _isRefreshing.value,
          showBackButton: !useBottomNavigation,
          leading: useBottomNavigation
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: _openDrawer,
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
                    _applySearch();
                  }
                });
              },
            ),
            SortActionButton(onTap: _showSortSheet),
            IconButton(
              tooltip: '新建歌单',
              icon: const Icon(Icons.add),
              onPressed: _createPlaylist,
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 2 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
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
                    _applySearch();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索歌单...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                              _applySearch();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Theme.of(context).appPanelColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                builder: (context) => RefreshIndicator(
                  onRefresh: _load,
                  child: _loading.value
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredPlaylists.value.isEmpty
                      ? const Center(child: Text('暂无歌单'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 160),
                          itemCount: _filteredPlaylists.value.length,
                          itemBuilder: (context, index) {
                            final p = _filteredPlaylists.value[index];
                      final scheme = Theme.of(context).colorScheme;
                      return Column(
                        key: ValueKey(p.guid),
                        children: [
                          ListTile(
                            leading: p.coverId != null && p.coverId!.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: CachedNetworkImage(
                                      imageUrl: FeiNiuApiClient.instance.coverUrl(p.coverId!, size: 48, updatedAt: p.updatedAt),
                                      httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                                      width: 48,
                                      height: 48,
                                      memCacheWidth: 48,
                                      memCacheHeight: 48,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) => Icon(Icons.queue_music_rounded, color: scheme.primary),
                                    ),
                                  )
                                : Icon(Icons.queue_music_rounded, color: scheme.primary),
                            title: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: null,
                            onTap: () async {
                              await Navigator.of(context).push(
                                buildAppPageRoute(
                                  (_) => PlaylistDetailPage(
                                    playlistId: p.guid,
                                    playlistName: p.name,
                                  ),
                                ),
                              );
                              if (!mounted) return;
                              await _load();
                            },
                            onLongPress: () => _showPlaylistSheet(p),
                          ),
                          if (index != _playlists.value.length - 1)
                            const Divider(height: 1),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistDetailPage extends StatefulWidget {
  final String playlistId;
  final String playlistName;

  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.playlistName = '歌单',
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage>
    with SignalsMixin {
  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;

  late final _loading = createSignal(true);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _originalSongs = createSignal<List<SongEntity>>([]);
  late final _showCovers = createSignal(true);
  late final _isSequentialPlay = createSignal(false);
  late final _multiSelect = createSignal(false);
  late final _selectedIds = createSignal<Set<String>>({});
  late final _sortKey = createSignal('default');
  late final _sortAscending = createSignal(true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _loading.value = true;
    try {
      final tracks = await _service.getPlaylistTracks(widget.playlistId);
      final songs = tracks
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      if (!mounted) return;
      _songs.value = songs;
      _originalSongs.value = List<SongEntity>.from(songs);
      _loading.value = false;
    } catch (e) {
      debugPrint('[PlaylistDetailPage] load error: $e');
      if (mounted) _loading.value = false;
    }
  }

  List<SongEntity> _sortedSongs(List<SongEntity> songs) {
    if (_sortKey.value == 'default') return songs;
    final list = List<SongEntity>.from(songs);
    int cmp(SongEntity a, SongEntity b) {
      switch (_sortKey.value) {
        case 'title':
          return a.title.compareTo(b.title);
        case 'artist':
          return a.artist.compareTo(b.artist);
        case 'album':
          return (a.album ?? '').compareTo(b.album ?? '');
        default:
          return 0;
      }
    }

    list.sort((a, b) => _sortAscending.value ? cmp(a, b) : -cmp(a, b));
    return list;
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SortSheet(
        options: const [
          SortOption(key: 'default', label: '添加时间', icon: Icons.sort),
          SortOption(key: 'title', label: '歌曲名称', icon: Icons.sort_by_alpha),
          SortOption(key: 'artist', label: '歌手名称', icon: Icons.person_outline),
          SortOption(key: 'album', label: '专辑名称', icon: Icons.album_outlined),
        ],
        currentKey: _sortKey.value,
        ascending: _sortAscending.value,
        onSelectKey: (key) {
          if (_sortKey.value != key) {
            _sortKey.value = key;
            _sortAscending.value = true;
          }
          _songs.value = key == 'default'
              ? _originalSongs.value
              : _sortedSongs(_songs.value);
        },
        onSelectAscending: (asc) {
          _sortAscending.value = asc;
          _songs.value = _sortKey.value == 'default'
              ? _originalSongs.value
              : _sortedSongs(_songs.value);
        },
      ),
    );
  }

  void _toggleSelectAll() {
    if (_songs.value.isEmpty) return;
    if (_selectedIds.value.length == _songs.value.length) {
      _selectedIds.value = {};
    } else {
      _selectedIds.value = _songs.value.map((e) => e.id).toSet();
    }
  }

  void _toggleMultiSelect() {
    _multiSelect.value = !_multiSelect.value;
    _selectedIds.value = {};
  }

  void _togglePlayMode() {
    _isSequentialPlay.value = !_isSequentialPlay.value;
    AppToast.show(context, _isSequentialPlay.value ? '已切换为顺序播放' : '已切换为随机播放');
  }

  Future<void> _removeSong(SongEntity song) async {
    try {
      await _service.removeTrack(widget.playlistId, song.id);
      if (!mounted) return;
      AppToast.show(context, '已移除');
      await _load();
    } catch (e) {
      if (mounted) AppToast.show(context, '移除失败', type: ToastType.error);
    }
  }

  Future<void> _removeSongsByIds(List<String> ids) async {
    for (final id in ids) {
      if (!mounted) break;
      try {
        await _service.removeTrack(widget.playlistId, id);
        if (!mounted) break;
        _songs.value = _songs.value.where((s) => s.id != id).toList();
        _originalSongs.value =
            _originalSongs.value.where((s) => s.id != id).toList();
        _selectedIds.value = Set<String>.from(_selectedIds.value)
          ..remove(id);
      } catch (_) {}
    }
    if (!mounted) return;
    AppToast.show(context, '已移除 $ids.length 首');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance;
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        extendBodyBehindAppBar: true,
        showMiniPlayer: !_multiSelect.value,
        appBar: AppTopBar(
          title: widget.playlistName,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Watch.builder(
          builder: (context) {
            final canReorder =
                _multiSelect.value && _sortKey.value == 'default';
            final totalCount = _songs.value.length;
            final selectedCount = _selectedIds.value.length;
            final isAllSelected = totalCount > 0 && selectedCount == totalCount;
            final bottomInset =
                MediaQuery.of(context).padding.bottom +
                (_multiSelect.value ? 160 : 80);
            return _loading.value
                ? const Center(child: CircularProgressIndicator())
                : _songs.value.isEmpty
                ? const Center(child: Text('歌单为空'))
                : Column(
                    children: [
                      MediaListHeader(
                        multiSelect: _multiSelect.value,
                        isAllSelected: isAllSelected,
                        selectedCount: selectedCount,
                        totalCount: totalCount,
                        playbackCount: totalCount,
                        isSequentialPlay: _isSequentialPlay.value,
                        onToggleSelectAll: _toggleSelectAll,
                        onPlay: () async {
                          if (_songs.value.isEmpty) return;
                          final queue = List<SongEntity>.from(_songs.value);
                          if (!_isSequentialPlay.value) {
                            queue.shuffle();
                          }
                          await player.playQueue(queue, 0);
                        },
                        onConfigurePlay: () {},
                        onTogglePlayMode: _togglePlayMode,
                        onSort: _showSortSheet,
                        onToggleMultiSelect: _toggleMultiSelect,
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: EdgeInsets.only(bottom: bottomInset),
                          itemCount: _songs.value.length,
                          itemBuilder: (context, index) {
                            final song = _songs.value[index];
                            return _buildSongTile(
                              context,
                              player: player,
                              song: song,
                              index: index,
                              canReorder: canReorder,
                            );
                          },
                        ),
                      ),
                      if (_multiSelect.value)
                        MultiSelectBottomBar(
                          actions: [
                            MultiSelectAction(
                              icon: Icons.queue_play_next,
                              label: '下一首播放',
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final selected = _songs.value
                                          .where(
                                            (s) => _selectedIds.value.contains(
                                              s.id,
                                            ),
                                          )
                                          .toList();
                                      await player.insertNext(selected);
                                      if (!context.mounted) return;
                                      AppToast.show(
                                        context,
                                        '已将 ${_selectedIds.value.length} 首歌曲加入下一首播放',
                                      );
                                      _toggleMultiSelect();
                                    },
                            ),
                            MultiSelectAction(
                              icon: Icons.playlist_add,
                              label: '添加到歌单',
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final ids = _selectedIds.value.toList();
                                      final added =
                                          await showAddToPlaylistDialog(
                                            context,
                                            songIds: ids,
                                          );
                                      if (!mounted) return;
                                      if (added) _toggleMultiSelect();
                                    },
                            ),
                            MultiSelectAction(
                              icon: Icons.delete_outline,
                              label: '移出',
                              isDestructive: true,
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) {
                                          return AlertDialog(
                                            title: const Text('移出选中歌曲'),
                                            content: Text(
                                              '确定要从歌单中移出这 ${_selectedIds.value.length} 首歌曲吗？',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  ctx,
                                                ).pop(false),
                                                child: const Text('取消'),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(ctx).pop(true),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: Colors.red,
                                                ),
                                                child: const Text('移出'),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                      if (confirmed != true) return;
                                      final ids = _selectedIds.value.toList();
                                      await _removeSongsByIds(ids);
                                      if (!mounted) return;
                                      _toggleMultiSelect();
                                    },
                            ),
                          ],
                        ),
                    ],
                  );
          },
        ),
        bottomNavIndex: useBottomNavigation ? 2 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }

  Widget _buildSongTile(
    BuildContext context, {
    required PlayerService player,
    required SongEntity song,
    required int index,
    required bool canReorder,
  }) {
    return ValueListenableBuilder<SongEntity?>(
      valueListenable: player.currentSong,
      builder: (context, current, _) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final isCurrent = current?.id == song.id;
        final isSelected = _selectedIds.value.contains(song.id);
        final titleColor = isCurrent
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface;
        final subtitleColor = isCurrent
            ? theme.colorScheme.primary
            : (isDark
                  ? Colors.white70
                  : const Color.fromARGB(255, 100, 100, 100));

        final tile = AppListTile(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: _multiSelect.value
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      size: 20,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.disabledColor,
                    ),
                  )
                : _coverOrIndex(context, song, index, subtitleColor),
          ),
          title: song.title,
          subtitle: song.artistDisplayName,
          titleColor: titleColor,
          trailing: null,
          onTap: () async {
            if (_multiSelect.value) {
              final next = _selectedIds.value.toSet();
              if (isSelected) {
                next.remove(song.id);
              } else {
                next.add(song.id);
              }
              _selectedIds.value = next;
              return;
            }
            await player.playQueue(_songs.value, index);
          },
          onLongPress: () {
            showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => SongDetailSheet(
                song: song,
                onUpdated: (_) => _load(),
                onOpenArtist: (artistName) {
                  Navigator.of(context).push(
                    buildAppPageRoute(
                      (_) => ArtistDetailPage(artistName: artistName),
                    ),
                  );
                },
                onOpenAlbum: (albumName) {
                  Navigator.of(context).push(
                    buildAppPageRoute(
                      (_) => AlbumDetailPage(albumName: albumName),
                    ),
                  );
                },
              ),
            );
          },
        );

        if (_multiSelect.value) return tile;

        return Dismissible(
          key: Key('playlist_${widget.playlistId}_${song.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            color: Colors.red,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (direction) async {
            return await showDialog<bool>(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: const Text('移除歌曲'),
                  content: const Text('确定要从歌单中移除这首歌曲吗？'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('移除'),
                    ),
                  ],
                );
              },
            );
          },
          onDismissed: (direction) async {
            await _removeSong(song);
          },
          child: tile,
        );
      },
    );
  }

  Widget _coverOrIndex(
    BuildContext context,
    SongEntity song,
    int index,
    Color subtitleColor,
  ) {
    if (!_showCovers.value) {
      return Center(
        child: Text(
          '${index + 1}',
          style: TextStyle(
            fontSize: 16,
            color: subtitleColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return ArtworkWidget(
      song: song,
      size: 48,
      borderRadius: 4,
      placeholder: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          song.title.trim().isEmpty
              ? '?'
              : song.title.trim().substring(0, 1).toUpperCase(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class PlaylistPickerSheet extends StatefulWidget {
  final List<String> songIds;

  const PlaylistPickerSheet({super.key, required this.songIds});

  @override
  State<PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<PlaylistPickerSheet>
    with SignalsMixin {
  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;

  late final _loading = createSignal(true);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _loading.value = true;
    final playlists = await _service.getPlaylistList();
    if (!mounted) return;
    _playlists.value = playlists;
    _loading.value = false;
  }

  Future<void> _createAndAdd() async {
    await _showPlaylistNameDialog(
      context,
      title: '新建歌单',
      initial: '',
      confirmText: '创建',
      fallbackName: '新建歌单',
      onSubmit: (name) async {
        final created = await _service.createPlaylist(name);
        for (final id in widget.songIds) {
          await _service.addTrack(created.guid, id);
        }
        if (!mounted) return;
        AppToast.show(context, '已收藏到歌单');
        Future.delayed(const Duration(milliseconds: 80), () {
          if (!mounted) return;
          Navigator.of(context).pop(true);
        });
      },
    );
  }

  Future<void> _addToPlaylist(FeiNiuPlaylist playlist) async {
    for (final id in widget.songIds) {
      await _service.addTrack(playlist.guid, id);
    }
    if (!mounted) return;
    AppToast.show(context, '已收藏到歌单');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetPanel(
      title: '选择歌单',
      expand: true,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Watch.builder(
        builder: (context) => _loading.value
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('新建歌单'),
                    onTap: _createAndAdd,
                  ),
                  const Divider(height: 1),
                  if (_playlists.value.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('暂无歌单')),
                    )
                  else
                    ..._playlists.value.map(
                      (p) => ListTile(
                        leading: const Icon(Icons.queue_music_rounded),
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: null,
                        onTap: () => _addToPlaylist(p),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

Future<bool> showAddToPlaylistDialog(
  BuildContext context, {
  required List<String> songIds,
}) async {
  final ids = songIds.where((e) => e.trim().isNotEmpty).toList();
  if (ids.isEmpty) return false;

  final service = FeiNiuPlaylistService.instance;
  final playlists = await service.getPlaylistList();
  if (!context.mounted) return false;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AppDialog(
        title: '添加到歌单',
        confirmText: '新建歌单',
        onConfirm: () {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (!context.mounted) return;
            _showPlaylistNameDialog(
              context,
              title: '新建歌单',
              initial: '',
              confirmText: '创建',
              fallbackName: '新建歌单',
              onSubmit: (name) async {
                final created = await service.createPlaylist(name);
                for (final id in ids) {
                  await service.addTrack(created.guid, id);
                }
                if (!context.mounted) return;
                AppToast.show(context, '已添加到歌单: ${created.name}');
              },
            );
          });
        },
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: playlists.isEmpty
              ? const Center(
                  child: Text('暂无歌单', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return AppListTile(
                      leading: const Icon(Icons.queue_music),
                      title: playlist.name,
                      subtitle: null,
                      onTap: () async {
                        for (final id in ids) {
                          await service.addTrack(playlist.guid, id);
                        }
                        if (!context.mounted) return;
                        Navigator.pop(dialogContext, true);
                        AppToast.show(context, '已添加到歌单: ${playlist.name}');
                      },
                    );
                  },
                ),
        ),
      );
    },
  );
  return result == true;
}

Future<void> _showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required String confirmText,
  required String? fallbackName,
  required Future<void> Function(String name) onSubmit,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _PlaylistNameDialog(
          title: title,
          initial: initial,
          confirmText: confirmText,
          fallbackName: fallbackName,
          onSubmit: onSubmit,
        ),
      );
    },
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String confirmText;
  final String? fallbackName;
  final Future<void> Function(String name) onSubmit;

  const _PlaylistNameDialog({
    required this.title,
    required this.initial,
    required this.confirmText,
    required this.fallbackName,
    required this.onSubmit,
  });

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty && widget.fallbackName == null) return;
    final name = trimmed.isEmpty ? widget.fallbackName! : trimmed;
    await widget.onSubmit(name);
  }

  Future<void> _submitAndClose() async {
    await _submit();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppSheetPanel(
      title: widget.title,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '歌单名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submitAndClose(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withAlpha(20)
                          : Colors.grey.withAlpha(26),
                      foregroundColor: isDark ? Colors.white70 : Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      elevation: 0,
                    ),
                    onPressed: _submitAndClose,
                    child: Text(
                      widget.confirmText,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
