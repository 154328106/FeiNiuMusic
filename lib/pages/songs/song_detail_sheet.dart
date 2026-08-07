import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/router/app_page_route.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/player/player_engine.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../components/common/app_list_tile.dart';
import '../../components/feedback/app_toast.dart';
import '../library/library_detail_pages.dart';
import '../library/playlists_page.dart';
import 'song_edit_page.dart';

class SongDetailSheet extends StatefulWidget {
  final SongEntity song;
  final ValueChanged<SongEntity>? onUpdated;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<String>? onOpenAlbum;
  final VoidCallback? onOpenPlayerAppearanceSettings;

  /// 额外操作项（如「移出最近播放」），渲染在「添加到歌单」之后。
  /// 由调用方决定是否传，避免所有入口都显示。
  final List<AppListTile>? extraActions;

  /// 是否显示播放控制（音量 / 倍速 / 解码器）。
  ///
  /// 这些选项只在**播放器界面**打开本面板时显示（右下角「⋯」、海报模式
  /// 「更多」），其余入口（列表/搜索/收藏等）打开的是「歌曲信息 + 管理」面板，
  /// 不显示播放控制。默认 false。
  final bool showPlayerControls;

  const SongDetailSheet({
    super.key,
    required this.song,
    this.onUpdated,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenPlayerAppearanceSettings,
    this.extraActions,
    this.showPlayerControls = false,
  });

  @override
  State<SongDetailSheet> createState() => _SongDetailSheetState();
}

class _SongDetailSheetState extends State<SongDetailSheet> {
  final FeiNiuFavoriteService _favoriteService =
      FeiNiuFavoriteService.instance;
  bool _isFavorite = false;
  bool _loadingFavorite = true;

  @override
  void initState() {
    super.initState();
    AppPlaybackVolumeSettings.ensureLoaded();
    AppPlaybackSpeedSettings.ensureLoaded();
    _loadFavoriteState();
  }

  Future<void> _loadFavoriteState() async {
    try {
      final isFav = await _favoriteService.isFavorite(widget.song.id);
      if (!mounted) return;
      setState(() {
        _isFavorite = isFav;
        _loadingFavorite = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingFavorite = false);
    }
  }

  Future<void> _toggleFavorite() async {
    if (_loadingFavorite) return;
    try {
      if (_isFavorite) {
        await _favoriteService.unfavorite(widget.song.id);
        if (!mounted) return;
        setState(() => _isFavorite = false);
        AppToast.show(context, '已取消收藏');
      } else {
        await _favoriteService.favorite(widget.song.id);
        if (!mounted) return;
        setState(() => _isFavorite = true);
        AppToast.show(context, '已收藏');
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '操作失败', type: ToastType.error);
    }
  }

  /// 点击解码 tag：弹出二选一解码器选择。选定后切换当前歌曲的解码引擎并关掉
  /// 面板（重载期间避免拖其他控件）。
  Future<void> _showDecoderPicker(BuildContext context, EngineKind current) async {
    final selected = await showModalBottomSheet<EngineKind>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DecoderPickerSheet(current: current),
    );
    if (selected == null || !mounted) return;
    final nav = Navigator.of(this.context);
    nav.pop();
    await PlayerService.instance.setDecoderEngine(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.scaffoldBackgroundColor;
    final secondaryTextColor = isDark
        ? Colors.white70
        : const Color.fromARGB(255, 100, 100, 100);
    final song = widget.song;
    final artist = song.artistDisplayName;
    final album = song.albumDisplayName;
    final primaryArtist = song.artistDisplayName;
    final canOpenAlbum = song.albumGuid != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[800] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _buildCover(theme, song),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$artist · $album',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _isFavorite ? theme.colorScheme.error : null,
                    ),
                    onPressed: _loadingFavorite ? null : _toggleFavorite,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 0.6),
            // 播放控制（音量/倍速/解码器）：仅播放器界面打开时显示，
            // 列表/搜索等入口打开的是「歌曲信息」面板，不显示播放控制。
            if (widget.showPlayerControls) ...[
              const _AppVolumeControl(),
              const _PlaybackSpeedControl(),
            ],
            AppListTile(
              leading: const Icon(Icons.queue_play_next),
              title: '下一首播放',
              onTap: () async {
                final api = FeiNiuApiClient.instance;
                final streamUrl = api.baseUrl.isNotEmpty
                    ? '${api.baseUrl}/music/api/v1/track/stream?guid=${song.id}'
                    : song.uri;
                final playable = song.copyWith(uri: streamUrl ?? '');
                await PlayerService.instance.playNext(playable);
                if (!context.mounted) return;
                AppToast.show(context, '已添加到下一首');
                Navigator.of(context).pop();
              },
            ),
            AppListTile(
              leading: const Icon(Icons.add_to_photos_outlined),
              title: '添加到歌单',
              onTap: () async {
                await showAddToPlaylistDialog(context, songIds: [song.id]);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
            AppListTile(
              leading: const Icon(Icons.edit_outlined),
              title: '编辑歌曲',
              onTap: () async {
                final nav = Navigator.of(context);
                nav.pop(); // 关闭详情 sheet
                final updated = await nav.push<SongEntity>(
                  buildAppPageRoute(
                    (_) => SongEditPage(song: widget.song),
                  ),
                );
                if (updated != null) {
                  // 激活回调刷新列表 + 更新当前播放/队列
                  widget.onUpdated?.call(updated);
                  await PlayerService.instance.updateSongMetadata(updated);
                }
              },
            ),
            if (widget.extraActions != null)
              ...widget.extraActions!,
            if (widget.onOpenPlayerAppearanceSettings != null)
              AppListTile(
                leading: const Icon(Icons.tune_rounded),
                title: '播放器界面设置',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  widget.onOpenPlayerAppearanceSettings?.call();
                },
              ),
            AppListTile(
              leading: const Icon(Icons.person),
              title: '歌手：$primaryArtist',
              onTap: () {
                final nav = Navigator.of(context);
                nav.pop();
                final callback = widget.onOpenArtist;
                if (callback != null) {
                  callback(primaryArtist);
                } else {
                  // 未提供回调时自行导航（默认行为，供未传回调的调用点使用）
                  final guid = song.firstArtistGuid;
                  if (guid != null) {
                    nav.push(
                      MaterialPageRoute(
                        builder: (_) => ArtistDetailPage(
                          artistName: primaryArtist,
                          artistGuid: guid,
                        ),
                      ),
                    );
                  }
                }
              },
            ),
            if (canOpenAlbum)
              AppListTile(
                leading: const Icon(Icons.album),
                title: '专辑：$album',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  final callback = widget.onOpenAlbum;
                  if (callback != null) {
                    callback(song.albumDisplayName);
                  } else {
                    // 未提供回调时自行导航（默认行为）
                    final guid = song.albumGuid;
                    if (guid != null) {
                      nav.push(
                        MaterialPageRoute(
                          builder: (_) => AlbumDetailPage(
                            albumName: song.albumDisplayName,
                            albumGuid: guid,
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
            if (song.audioSpec != null && song.audioSpec!.isNotEmpty)
              AppListTile(
                leading: const Icon(Icons.info_outline),
                title: '音频规格',
                subtitle: song.audioSpec,
                // 解码器 tag 属于播放控制：仅播放器界面打开时显示，点击可切换。
                trailing: widget.showPlayerControls
                    ? ValueListenableBuilder<EngineKind>(
                        valueListenable: PlayerService.instance.decoderEngine,
                        builder: (context, engine, _) => _DecoderTag(
                          engine: engine,
                          onTap: () => _showDecoderPicker(context, engine),
                        ),
                      )
                    : null,
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(ThemeData theme, SongEntity song) {
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      final coverUrl =
          FeiNiuApiClient.instance.coverUrl(song.coverId!, size: 52, updatedAt: song.updatedAt);
      return CachedNetworkImage(
        imageUrl: coverUrl,
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
        width: 52,
        height: 52,
        memCacheWidth: 52,
        memCacheHeight: 52,
        fit: BoxFit.cover,
        placeholder: (_, _) => _coverPlaceholder(theme, song.title),
        errorWidget: (_, _, _) => _coverPlaceholder(theme, song.title),
      );
    }
    return _coverPlaceholder(theme, song.title);
  }

  Widget _coverPlaceholder(ThemeData theme, String title) {
    final letter = title.trim().isEmpty ? '?' : title.trim().substring(0, 1);
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AppVolumeControl extends StatelessWidget {
  const _AppVolumeControl();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 与下方 AppListTile 的标题对齐：同用 ListTileTheme 的 contentPadding，
    // leading（图标宽 24）与标题之间留 16（ListTile 默认 horizontalTitleGap）。
    final tilePadding = ListTileTheme.of(context).contentPadding?.resolve(
          Directionality.of(context),
        ) ??
        const EdgeInsets.symmetric(horizontal: 16);
    return Padding(
      padding: EdgeInsets.only(
        left: tilePadding.left,
        right: tilePadding.right,
        top: 8,
        bottom: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: Icon(
              Icons.volume_down_rounded,
              size: 24,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: AppPlaybackVolumeSettings.volume,
              builder: (context, volume, _) {
                final percent = (volume * 100).round();
                return Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        '音量',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: volume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '$percent%',
                        onChanged: AppPlaybackVolumeSettings.setVolume,
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '$percent%',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放速度倍率滑条（0.1×–5.0×，0.1 步进）。与 [_AppVolumeControl] 完全同构：
/// leading 图标 + 标题「倍速」（宽 42）+ 滑条 + 右侧倍速值（宽 42 右对齐）。
/// 离散滑条，每格 0.1，松手即持久化。
class _PlaybackSpeedControl extends StatelessWidget {
  const _PlaybackSpeedControl();

  /// 显示用倍速文本：去尾零（1×、1.5×、2.5×、5×）。
  static String _formatSpeed(double speed) {
    final text = speed == speed.roundToDouble()
        ? speed.toInt().toString()
        : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    return '$text×';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 与下方 AppListTile 的标题对齐：同用 ListTileTheme 的 contentPadding。
    final tilePadding = ListTileTheme.of(context).contentPadding?.resolve(
          Directionality.of(context),
        ) ??
        const EdgeInsets.symmetric(horizontal: 16);
    return Padding(
      padding: EdgeInsets.only(
        left: tilePadding.left,
        right: tilePadding.right,
        top: 8,
        bottom: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: Icon(
              Icons.speed_rounded,
              size: 24,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: AppPlaybackSpeedSettings.speed,
              builder: (context, persisted, _) {
                final valueText = _formatSpeed(persisted);
                return Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        '倍速',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: persisted,
                        min: AppPlaybackSpeedSettings.minSpeed,
                        max: AppPlaybackSpeedSettings.maxSpeed,
                        divisions: 49,
                        label: valueText,
                        onChanged: (v) => PlayerService.instance.setSpeed(v),
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        valueText,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 解码引擎标签：显示当前歌曲由哪个播放器解码。可点击弹出解码器选择。
class _DecoderTag extends StatelessWidget {
  final EngineKind engine;
  final VoidCallback? onTap;
  const _DecoderTag({required this.engine, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isMediaKit = engine == EngineKind.mediaKit;
    final color = isMediaKit
        ? const Color(0xFF6750A4) // 紫：FFmpeg 软解
        : const Color(0xFF00897B); // 青绿：系统解码器
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          isMediaKit ? 'FFmpeg' : '系统解码',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 解码器二选一选择面板：系统解码（just_audio / ExoPlayer）或 FFmpeg（media_kit）。
class _DecoderPickerSheet extends StatelessWidget {
  final EngineKind current;

  const _DecoderPickerSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.scaffoldBackgroundColor;
    final secondaryTextColor = isDark
        ? Colors.white70
        : const Color.fromARGB(255, 100, 100, 100);

    Widget tile(EngineKind kind, String title, String subtitle, Color color) {
      final selected = kind == current;
      return AppListTile(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? color : secondaryTextColor,
        ),
        title: title,
        titleColor: selected ? color : null,
        subtitle: subtitle,
        onTap: () => Navigator.of(context).pop(kind),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[800] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '选择解码器',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            tile(
              EngineKind.justAudio,
              '系统解码',
              'ExoPlayer 硬件/系统解码，省电、支持倍速',
              const Color(0xFF00897B),
            ),
            tile(
              EngineKind.mediaKit,
              'FFmpeg 软解',
              'media_kit / libmpv，兼容性最强，支持无损与罕见格式',
              const Color(0xFF6750A4),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
