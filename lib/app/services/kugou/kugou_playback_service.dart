import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'kugou_api_client.dart';
import 'kugou_models.dart';

/// 一首歌取址与兜底要用到的信息。
class _SongMeta {
  const _SongMeta({
    required this.albumId,
    required this.albumAudioId,
    required this.keyword,
    required this.durationMs,
  });

  final String? albumId;
  final String? albumAudioId;

  /// 「歌名 歌手」，给第三方音源做匹配用。
  final String keyword;
  final int durationMs;
}

class _ResolvedUrl {
  _ResolvedUrl(this.url, this.resolvedAt);

  final String url;
  final DateTime resolvedAt;

  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > KugouPlaybackService.urlTtl;
}

/// 酷狗的播放地址解析与模型转换。
class KugouPlaybackService {
  KugouPlaybackService._();

  static final KugouPlaybackService instance = KugouPlaybackService._();

  /// 地址缓存时长。
  ///
  /// 原来 20 分钟，一小时的连续收听要重探三轮 —— 每轮都要为会员曲各问一次
  /// 音源，请求量就是这么堆起来的。拉到 45 分钟。
  ///
  /// 敢拉长是因为过期有兜底：地址失效会让播放打不开，播放器的错误恢复会
  /// 带 force 重取一次（见 player_service 里的 `force: forceRefresh`），
  /// 最坏就是那一首多花一次请求。
  static const Duration urlTtl = Duration(minutes: 45);

  final Map<String, _ResolvedUrl> _cache = {};

  /// 确认拿不到地址的歌。没有这份记录，每次起播都会为它们重跑一整套请求。
  final Set<String> _unresolvable = {};

  /// 取址与兜底要用到的信息，从 SongEntity 里带过来。
  ///
  /// keyword（歌名+歌手）和时长是给第三方音源用的：音源按「搜歌名再比
  /// 时长」匹配，拿酷狗的文件 hash 去查它一条都对不上 —— 之前日志里
  /// 「kg/`<hash>` 全部未命中」就是这么来的。
  final Map<String, _SongMeta> _meta = {};

  /// 同一首歌的并发请求合并成一次。
  ///
  /// 日志里同一个 hash 会被连着问两遍（起播路径偶尔并发触发两次
  /// prepareQueue），请求量凭空翻倍 —— 之前把聆澜打成 429 就是这么来的。
  /// 网易云那边早就有这道合并，酷狗漏了。
  final Map<String, Future<String?>> _inflight = {};

  Future<String?> resolveStreamUrl(String hash, {bool force = false}) async {
    if (!force) {
      final cached = _cache[hash];
      if (cached != null && !cached.isExpired) return cached.url;
      if (_unresolvable.contains(hash)) return null;
      final pending = _inflight[hash];
      if (pending != null) return pending;
    }
    final future = _resolveOnce(hash);
    _inflight[hash] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(hash);
    }
  }

  Future<String?> _resolveOnce(String hash) async {
    final meta = _meta[hash];
    try {
      var url = await KugouApiClient.instance.songUrl(
        hash,
        albumId: meta?.albumId,
        albumAudioId: meta?.albumAudioId,
      );
      // 官方给不出（会员曲）就问第三方音源，按歌名+歌手+时长匹配。
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'kg',
        songId: hash,
        keyword: meta?.keyword,
        durationMs: meta?.durationMs ?? 0,
      );
      if (url == null) {
        _unresolvable.add(hash);
        return null;
      }
      final secure = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      _cache[hash] = _ResolvedUrl(secure, DateTime.now());
      return secure;
    } on KugouApiException catch (e) {
      debugPrint('[Kugou] 取播放地址失败 $hash：${e.message}');
      return null;
    }
  }

  /// 播放前筛掉取不到地址的歌。
  ///
  /// 酷狗这条比 QQ 靠谱：它的取址接口会明确给 status / error_code，拿不到
  /// 就是真拿不到，不会像 QQ 那样发一个打不开的死链回来充数。
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final pending = <String>[];
    for (final song in songs) {
      final hash = SongSource.decodeKugou(song.id);
      if (hash == null) continue;
      _rememberRefs(song, hash);
      if (_cache[hash]?.isExpired == false) continue;
      if (_unresolvable.contains(hash)) continue;
      pending.add(hash);
    }

    // 限并发：网易云那边一次并发一百个把第三方音源打成 429，教训在前。
    const batch = 8;
    for (var i = 0; i < pending.length; i += batch) {
      await Future.wait([
        for (final hash in pending.skip(i).take(batch)) resolveStreamUrl(hash),
      ]);
    }

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final hash = SongSource.decodeKugou(song.id);
      if (hash == null) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(hash)) {
        dropped++;
        continue;
      }
      playable.add(song);
    }
    debugPrint(
      '[Kugou] 队列 ${songs.length} 首：可播 ${playable.length}，跳过 $dropped',
    );
    return playable;
  }

  /// 记下取址与兜底要用的信息。
  ///
  /// album 引用借 codec / audioSpec 两个既有字段存（见 SongSource 里关于
  /// 不改数据库 schema 的说明）。
  void _rememberRefs(SongEntity song, String hash) {
    if (_meta.containsKey(hash)) return;
    _meta[hash] = _SongMeta(
      albumId: song.codec,
      albumAudioId: song.audioSpec,
      keyword: '${song.title} ${song.artistDisplayName}'.trim(),
      durationMs: song.durationMs ?? 0,
    );
  }

  void invalidate(String hash) {
    _cache.remove(hash);
    _unresolvable.remove(hash);
  }

  void clear() {
    _cache.clear();
    _unresolvable.clear();
    _inflight.clear();
  }

  /// 播放时要带的请求头。
  static Map<String, String> streamHeaders() => const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  static SongEntity toSongEntity(KugouSong song) {
    return SongEntity(
      id: SongSource.encodeKugou(song.hash),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      uri: 'https://www.kugou.com/song/#hash=${song.hash}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs,
      coverId: song.coverUrl,
      // 借这两个既有字段存取址要用的引用，不为它们新开数据库列。
      codec: song.albumId,
      audioSpec: song.albumAudioId,
      format: 'mp3',
      isVip: song.isVip,
    );
  }
}
