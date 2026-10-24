import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/song_state.dart';

/// 本地收藏：跨所有源、不依赖任何账号的「我喜欢」。
///
/// 现在各家收藏都绑账号（网易点赞 / QQ·酷狗歌单），不登录就收藏不了 —— 而咪咕、
/// 酷我这些平时就不登录。这份本地收藏把整首 [SongEntity] 存下来（和
/// [PlayedSongCache] 同一套序列化），任何源的歌点一下心形就进来，下次直接点开
/// 播（播放按 id 前缀走现有解析，不碰账号）。
///
/// 存 SharedPreferences：收藏不是高频写，直接即时落盘（不像播放历史要攒）。
class LocalFavoritesStore {
  LocalFavoritesStore._();
  static final LocalFavoritesStore instance = LocalFavoritesStore._();

  static const String _prefsKey = 'local.favorites.v1';
  static const int _maxEntries = 2000;

  /// id → 歌曲，插入序 = 收藏时间从旧到新（展示时反转成新→旧）。
  final Map<String, SongEntity> _songs = {};

  /// 收藏变化时自增，供页面/心形重建。
  final ValueNotifier<int> revision = ValueNotifier(0);

  Future<void>? _loading;
  bool get isLoaded => _loading != null;

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
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[LocalFav] 读取失败：$e');
    }
  }

  bool isFavorite(String id) => _songs.containsKey(id);

  /// 收藏 / 取消，返回操作后的状态（true=已收藏）。
  Future<bool> toggle(SongEntity song) async {
    if (isFavorite(song.id)) {
      await remove(song.id);
      return false;
    }
    await add(song);
    return true;
  }

  Future<void> add(SongEntity song) async {
    if (song.id.isEmpty) return;
    _songs.remove(song.id); // 重新收藏挪到最新。
    _songs[song.id] = song;
    while (_songs.length > _maxEntries) {
      _songs.remove(_songs.keys.first);
    }
    await _persist();
    revision.value++;
  }

  Future<void> remove(String id) async {
    if (_songs.remove(id) == null) return;
    await _persist();
    revision.value++;
  }

  /// 全部本地收藏，新→旧。
  List<SongEntity> list() => _songs.values.toList().reversed.toList();

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = [for (final s in _songs.values) s.toMap()];
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[LocalFav] 保存失败：$e');
    }
  }
}
