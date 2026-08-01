import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';
import '../songs/song_detail_sheet.dart';

class GenresPage extends StatefulWidget {
  const GenresPage({super.key});

  @override
  State<GenresPage> createState() => _GenresPageState();
}

const String genresPrefsSortKey = 'genres_sort_key_v1';
const String genresPrefsSortAscending = 'genres_sort_ascending_v1';
const String genresDefaultSortKey = 'trackCount';
const bool genresDefaultAscending = false;

class _GenresPageState extends State<GenresPage> with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _genres = createSignal<List<FeiNiuGenre>>([]);
  late final _sortKey = createSignal(genresDefaultSortKey);
  late final _ascending = createSignal(genresDefaultAscending);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var key = (prefs.getString(genresPrefsSortKey) ?? genresDefaultSortKey).trim();
    if (key.isEmpty) key = genresDefaultSortKey;
    _sortKey.value = key;
    _ascending.value = prefs.getBool(genresPrefsSortAscending) ?? genresDefaultAscending;
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(genresPrefsSortKey, _sortKey.value);
    await prefs.setBool(genresPrefsSortAscending, _ascending.value);
  }

  Future<void> _load() async {
    _loading.value = true;
    try {
      final sort = '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}';
      final pageData = await _api.getGenreList(page: 1, size: 200, sort: sort);
      if (mounted) _genres.value = pageData.list;
    } catch (e) {
      debugPrint('[GenresPage] load error: $e');
    }
    if (mounted) _loading.value = false;
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '风格排序',
          options: const [
            SortOption(key: 'name', label: '风格名', icon: Icons.sort_by_alpha),
            SortOption(
              key: 'trackCount',
              label: '歌曲数',
              icon: Icons.music_note_outlined,
            ),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _savePrefs();
            _load();
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _savePrefs();
            _load();
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '风格',
          showBackButton: !useBottomNavigation,
          leading: useBottomNavigation
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            SortActionButton(onTap: _showSortSheet),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        body: Watch.builder(
          builder: (context) {
            if (_loading.value) {
              return const Center(child: CircularProgressIndicator());
            }

            final genres = _genres.value;
            if (genres.isEmpty) {
              return Center(
                child: Text('暂无风格', style: TextStyle(color: scheme.onSurfaceVariant)),
              );
            }

            return RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 160),
                itemCount: genres.length,
                itemBuilder: (context, index) {
                  final g = genres[index];
                  final initial = g.name.isNotEmpty ? g.name.characters.first.toUpperCase() : '?';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primary.withValues(alpha: 0.15),
                      child: Text(initial, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                    ),
                    title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${g.trackCount} 首'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.of(context).push(
                        buildAppPageRoute(
                          (_) => GenreDetailPage(genre: g),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class GenreDetailPage extends StatefulWidget {
  final FeiNiuGenre genre;

  const GenreDetailPage({super.key, required this.genre});

  @override
  State<GenreDetailPage> createState() => _GenreDetailPageState();
}

class _GenreDetailPageState extends State<GenreDetailPage> with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;

  late final _loading = createSignal(true);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _sortKey = createSignal('createdAt');
  late final _ascending = createSignal(false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _apiSortParam() {
    return '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}';
  }

  Future<void> _load({bool forceRefresh = false}) async {
    _loading.value = true;
    try {
      final pageData = await _api.getGenreTracks(
        genreGUID: widget.genre.guid,
        page: 1,
        size: 300,
        sort: _apiSortParam(),
      );
      if (!mounted) return;
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      _songs.value = songs;
    } catch (e) {
      debugPrint('[GenreDetailPage] load error: $e');
    }
    if (mounted) _loading.value = false;
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '排序',
          options: const [
            SortOption(key: 'createdAt', label: '添加日期', icon: Icons.access_time),
            SortOption(key: 'artistName', label: '歌手', icon: Icons.person),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _load(forceRefresh: true);
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _load(forceRefresh: true);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: widget.genre.name,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          SortActionButton(onTap: _showSortSheet),
        ],
      ),
      body: Watch.builder(
        builder: (context) {
          if (_loading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          final songs = _songs.value;
          if (songs.isEmpty) {
            return Center(
              child: Text('暂无歌曲', style: TextStyle(color: scheme.onSurfaceVariant)),
            );
          }

          return RefreshIndicator(
            onRefresh: () => _load(forceRefresh: true),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return InkWell(
                  onTap: () => _player.playQueue(songs, index),
                  onLongPress: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (_) => SongDetailSheet(song: song),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        ArtworkWidget(song: song, size: 48, borderRadius: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(song.artistDisplayName, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
