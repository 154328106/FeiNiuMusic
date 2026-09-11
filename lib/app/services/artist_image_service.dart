import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'qq/qq_api_client.dart';

/// 按歌手名去 QQ 取真人头像。
///
/// 起因：飞牛 NAS 的 `artist.coverId` 是拿该歌手某张专辑的封面充数的，所以
/// 歌手列表里清一色是专辑封面。QQ 的歌手图有独立的一套地址
/// （`T001R500x500M000{singer_mid}.jpg`，和专辑图 `T002` 同源），而 singer_mid
/// 在搜索结果里本来就有。
///
/// **只认名字完全对得上的**：搜索是模糊的，随便取第一条会给冷门歌手配上
/// 一张别人的脸 —— 那比继续用专辑封面糟得多。宁可没有。
class ArtistImageService {
  ArtistImageService._();

  static final ArtistImageService instance = ArtistImageService._();

  static const String _prefsKey = 'artist_photo_cache_v1';

  /// 查不到也记下来，免得每次滚到这个歌手都重查一遍。但不能永久记死 ——
  /// 今天 QQ 没有的人，过阵子可能就有了。
  static const Duration _missTtl = Duration(days: 7);

  /// 两条通道 + 最小间隔。歌手列表一屏能有几十个，不限速等于对着 QQ 刷屏。
  static const int _lanes = 2;
  static const Duration _minInterval = Duration(milliseconds: 150);

  /// 名字 → 头像地址。空串表示「查过了，QQ 没有」。
  final Map<String, String> _cache = {};

  /// 空结果的记录时刻，用来做 [_missTtl]。
  final Map<String, int> _missAt = {};

  /// 同一个名字同时被问多次时共用一次请求（列表和详情页会一起问）。
  final Map<String, Future<String?>> _inFlight = {};

  final List<Future<void>> _gates = List.filled(_lanes, Future.value());
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _nextLane = 0;

  Future<void>? _loading;
  bool _dirty = false;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final hits = decoded['hits'];
      if (hits is Map) {
        hits.forEach((k, v) {
          if (k is String && v is String) _cache[k] = v;
        });
      }
      final misses = decoded['misses'];
      if (misses is Map) {
        misses.forEach((k, v) {
          if (k is String && v is int) _missAt[k] = v;
        });
      }
    } catch (_) {
      // 缓存读不出来就当没有，不该挡住页面。
    }
  }

  /// 写盘合并成一次：滚一屏会产生几十次命中，逐次写等于反复序列化整张表。
  void _scheduleSave() {
    if (_dirty) return;
    _dirty = true;
    Timer(const Duration(seconds: 2), () async {
      _dirty = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefsKey,
          jsonEncode({'hits': _cache, 'misses': _missAt}),
        );
      } catch (_) {
        // 存不下就算了，下次启动重查而已。
      }
    });
  }

  /// 取歌手头像地址。查不到返回 null，调用方自己回退。
  Future<String?> photoUrl(String artistName) async {
    final key = _key(artistName);
    if (key.isEmpty) return null;
    await ensureLoaded();

    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    final missedAt = _missAt[key];
    if (missedAt != null) {
      final age = DateTime.now().millisecondsSinceEpoch - missedAt;
      if (age < _missTtl.inMilliseconds) return null;
      _missAt.remove(key);
    }

    final running = _inFlight[key];
    if (running != null) return running;
    final future = _lookup(key, artistName);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<String?> _lookup(String key, String artistName) {
    final completer = Completer<String?>();
    final lane = _nextLane;
    _nextLane = (_nextLane + 1) % _lanes;
    _gates[lane] = _gates[lane].then((_) async {
      try {
        final since = DateTime.now().difference(_lastAt);
        final wait = _minInterval - since;
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        final url = await _search(artistName);
        _lastAt = DateTime.now();
        if (url != null) {
          _cache[key] = url;
        } else {
          _missAt[key] = DateTime.now().millisecondsSinceEpoch;
        }
        _scheduleSave();
        completer.complete(url);
      } catch (_) {
        _lastAt = DateTime.now();
        // 出错不记 miss：网络抽风不该让这个歌手一周都不再试。
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<String?> _search(String artistName) async {
    final songs = await QQApiClient.instance.searchSongs(artistName, limit: 10);
    final want = _key(artistName);
    for (final song in songs) {
      for (final singer in song.singers) {
        if (_key(singer.name) == want) {
          return 'https://y.gtimg.cn/music/photo_new/'
              'T001R500x500M000${singer.mid}.jpg';
        }
      }
    }
    return null;
  }

  /// 比对用的规范名：去空白、转小写。搜索返回的写法和库里常差个空格或大小写。
  String _key(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}
