import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「热门歌手」的头像：歌手名 → 封面地址，存到本地，下次直接用。
///
/// 酷我 / 咪咕没有能用的热门歌手接口，首页「歌手」是一组写好的名字，头像靠
/// 「搜这个人 → 拿第一首歌的封面」。原来每次打开都要把 20 个人逐个搜完才显示
/// 列表（4 并发 × 5 批，咪咕一次搜 0.3~0.5 秒），手机上要卡好几秒。现在：
/// - 搜到的头像存进 SharedPreferences，第二次打开一个请求都不发；
/// - 第一次最多等 [wait]，搜到多少先显示多少，剩下的在后台接着搜，下次就齐了。
class ArtistCoverCache {
  ArtistCoverCache(
    this.prefsKey,
    this.fetch, {
    this.concurrency = 8,
    this.wait = const Duration(milliseconds: 1200),
  });

  final String prefsKey;
  final Future<String?> Function(String name) fetch;
  final int concurrency;
  final Duration wait;

  final Map<String, String> _covers = {};
  bool _loaded = false;
  Future<void>? _filling;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        m.forEach((k, v) {
          if (v is String && v.isNotEmpty) _covers['$k'] = v;
        });
      }
    } catch (_) {}
  }

  /// 给 [names] 取头像。返回当前已知的（可能不全）。
  Future<Map<String, String>> covers(List<String> names) async {
    await _load();
    final missing = [
      for (final n in names)
        if (!_covers.containsKey(n)) n,
    ];
    if (missing.isNotEmpty) {
      final filling = _filling ??= _fill(missing).whenComplete(() {
        _filling = null;
      });
      await Future.any([filling, Future<void>.delayed(wait)]);
    }
    return Map.of(_covers);
  }

  Future<void> _fill(List<String> names) async {
    var added = false;
    for (var i = 0; i < names.length; i += concurrency) {
      final batch = names.skip(i).take(concurrency).toList();
      final got = await Future.wait([
        for (final n in batch) fetch(n).catchError((_) => null),
      ]);
      for (var j = 0; j < batch.length; j++) {
        final c = got[j];
        if (c != null && c.isNotEmpty) {
          _covers[batch[j]] = c;
          added = true;
        }
      }
    }
    if (!added) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(_covers));
    } catch (e) {
      debugPrint('[ArtistCoverCache] $prefsKey 保存失败：$e');
    }
  }
}
