import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/song_state.dart';

/// 播过的歌的本地留档。
///
/// 解决两件一直是空的事：
///
/// - **听歌统计**：统计表里只存 songId，页面靠 `SongDao.fetchByIds` 把 id
///   换回歌曲信息 —— 那张表是**飞牛的曲库**。网易云 / 酷狗的 id（`ne:` /
///   `kg:` 前缀）从来不在里面，于是每一条都查不到、被 `continue` 跳过，
///   整页就是空的。换源之后统计只对飞牛的歌有效，其实是这个原因。
/// - **公网源的「最近播放」**：酷狗没有免登录也稳定的播放历史接口，与其
///   猜一个接口，不如就用本机播过的记录 —— 那本来就是用户想看的东西。
///
/// 存在 SharedPreferences 里而不是新开一张表：这份数据是纯粹的缓存，丢了
/// 只影响这两处展示，不值得为它加一次数据库迁移。
class PlayedSongCache {
  PlayedSongCache._();

  static final PlayedSongCache instance = PlayedSongCache._();

  static const String _prefsKey = 'played.songs.v1';

  /// 留档上限。一条大约 150 字节，500 条约 75KB。
  static const int _maxEntries = 500;

  /// id → 歌曲，按最后播放时间从新到旧。用 LinkedHashMap 的插入序表达顺序。
  final Map<String, SongEntity> _songs = {};

  Future<void>? _loading;
  Timer? _saveDebounce;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final song = SongEntity.fromMap(Map<String, dynamic>.from(item));
          _songs[song.id] = song;
        } catch (_) {
          // 单条坏了就跳过，不该让整份留档作废。
        }
      }
    } catch (e) {
      debugPrint('[PlayedSongs] 读取失败：$e');
    }
  }

  /// 记一首刚播的歌。同一首重复播只更新位置，不重复占位。
  void record(SongEntity song) {
    if (song.id.isEmpty) return;
    _songs.remove(song.id);
    _songs[song.id] = song;
    while (_songs.length > _maxEntries) {
      _songs.remove(_songs.keys.first);
    }
    // 切歌很频繁，攒一会儿再落盘。
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 5), _persist);
  }

  /// 最近播过的歌，从新到旧。
  ///
  /// [idPrefix] 用来只要某一个源的歌：酷狗是 `kg:`，网易云是 `ne:`。
  List<SongEntity> recent({int limit = 30, String? idPrefix}) {
    final result = <SongEntity>[];
    for (final id in _songs.keys.toList().reversed) {
      if (idPrefix != null && !id.startsWith(idPrefix)) continue;
      result.add(_songs[id]!);
      if (result.length >= limit) break;
    }
    return result;
  }

  /// 按 id 取，给听歌统计补那些不在飞牛曲库里的歌。
  Map<String, SongEntity> byIds(Iterable<String> ids) {
    final result = <String, SongEntity>{};
    for (final id in ids) {
      final song = _songs[id];
      if (song != null) result[id] = song;
    }
    return result;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = [for (final song in _songs.values) song.toMap()];
      await prefs.setString(_prefsKey, jsonEncode(list));
    } catch (e) {
      debugPrint('[PlayedSongs] 保存失败：$e');
    }
  }

  /// App 退到后台时立刻落盘，别让攒着的那几条丢掉。
  Future<void> flush() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persist();
  }
}
