import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';
import '../../pages/library/playlists_page.dart' show showAddToPlaylistDialog;
import '../feedback/app_toast.dart';
import 'multi_select_bottom_bar.dart';

/// 歌曲列表页多选通用能力。
///
/// 为歌曲/收藏/最近播放/歌手详情/专辑详情/风格详情等页面提供：
///   - 多选状态（`_multiSelect` / `_selectedIds`，按 `song.id` 存 `Set`，天然跨分页保留）；
///   - 全选 / 取消全选 / 点选单个；
///   - 三个共享操作：添加到播放队列（复用 [PlayerService.insertNext]）、
///     添加到歌单（[showAddToPlaylistDialog]）、添加到收藏（循环 favorite）。
///
/// 依赖 [SignalsMixin] 的自动重建：signal 变化即触发 setState，与各页现有渲染一致。
/// 页面需实现 [multiSelectSongs]（当前可见歌曲列表，收藏/最近页为过滤后的列表）。
mixin SongMultiSelectMixin<T extends StatefulWidget>
    on State<T>, SignalsMixin<T> {
  /// 页面提供：当前可见歌曲列表（收藏/最近页为过滤后的 `_songs`）。
  List<SongEntity> get multiSelectSongs;

  /// 页面提供：操作成功后的收尾（默认仅退出多选；歌单详情页移出后需 reload）。
  Future<void> Function()? get onMultiSelectDone => null;

  late final _multiSelect = createSignal(false);
  late final _selectedIds = createSignal<Set<String>>({});

  bool get isMultiSelecting => _multiSelect.value;
  int get selectedCount => _selectedIds.value.length;
  bool isSongSelected(String id) => _selectedIds.value.contains(id);
  List<SongEntity> get selectedSongs =>
      multiSelectSongs.where((s) => _selectedIds.value.contains(s.id)).toList();

  void toggleMultiSelect() {
    _multiSelect.value = !_multiSelect.value;
    _selectedIds.value = {};
  }

  void exitMultiSelect() {
    if (_multiSelect.value) toggleMultiSelect();
  }

  void toggleSelectAll() {
    final songs = multiSelectSongs;
    if (songs.isEmpty) return;
    _selectedIds.value = _selectedIds.value.length == songs.length
        ? <String>{}
        : songs.map((e) => e.id).toSet();
  }

  void toggleSongSelection(String id) {
    final next = _selectedIds.value.toSet();
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    _selectedIds.value = next;
  }

  /// tile 左侧：多选中显示勾选圈（保留原封面在右侧）。
  Widget selectionLeading(BuildContext context, Widget? original, bool selected) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          selected ? Icons.check_circle : Icons.circle_outlined,
          size: 20,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).disabledColor,
        ),
        const SizedBox(width: 12),
        original ?? const SizedBox.shrink(),
      ],
    );
  }

  /// 添加到播放队列：把选中的歌曲插入当前曲目之后（下一首播放）。
  Future<void> addSelectedToQueue() async {
    final songs = selectedSongs;
    if (songs.isEmpty) return;
    await PlayerService.instance.insertNext(songs);
    if (!mounted) return;
    AppToast.show(context, '已将 ${songs.length} 首歌曲加入下一首播放');
    await onMultiSelectDone?.call();
  }

  /// 添加到歌单：弹出歌单选择，批量添加选中的歌曲。
  Future<void> addSelectedToPlaylist() async {
    final ids = _selectedIds.value.toList();
    if (ids.isEmpty) return;
    final added = await showAddToPlaylistDialog(context, songIds: ids);
    if (!mounted) return;
    if (added) await onMultiSelectDone?.call();
  }

  /// 添加到收藏：逐首收藏（接口无批量）。部分失败时提示失败数量。
  Future<void> addSelectedToFavorite() async {
    final ids = _selectedIds.value.toList();
    if (ids.isEmpty) return;
    final failed =
        await FeiNiuFavoriteService.instance.favoriteAll(ids);
    if (!mounted) return;
    final ok = ids.length - failed;
    AppToast.show(
      context,
      failed == 0
          ? '已收藏 $ok 首歌曲'
          : '已收藏 $ok 首，$failed 首失败',
      type: failed == 0 ? ToastType.success : ToastType.error,
    );
    await onMultiSelectDone?.call();
  }

  /// 构建多选底部操作栏；[includeFavorite] 为 false 时隐藏「添加到收藏」（收藏页）。
  Widget buildMultiSelectBar({bool includeFavorite = true}) {
    final empty = _selectedIds.value.isEmpty;
    final actions = <MultiSelectAction>[
      MultiSelectAction(
        icon: Icons.queue_play_next,
        label: '添加到播放队列',
        onTap: empty ? null : () => addSelectedToQueue(),
      ),
      MultiSelectAction(
        icon: Icons.playlist_add,
        label: '添加到歌单',
        onTap: empty ? null : () => addSelectedToPlaylist(),
      ),
      if (includeFavorite)
        MultiSelectAction(
          icon: Icons.favorite_border_rounded,
          label: '添加到收藏',
          onTap: empty ? null : () => addSelectedToFavorite(),
        ),
    ];
    return MultiSelectBottomBar(actions: actions);
  }
}
