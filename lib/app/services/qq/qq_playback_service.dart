import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'qq_api_client.dart';
import 'qq_models.dart';

class _ResolvedUrl {
  _ResolvedUrl(this.url, this.resolvedAt);

  final String url;
  final DateTime resolvedAt;

  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > QQPlaybackService.urlTtl;
}

/// QQ 音乐的播放地址解析与模型转换。
///
/// 和网易云一个路子：地址是带 vkey 的临时直链，存进数据库过一阵就 403，
/// 所以 `SongEntity.uri` 只是占位，真播之前必须重新取。
class QQPlaybackService {
  QQPlaybackService._();

  static final QQPlaybackService instance = QQPlaybackService._();

  /// vkey 官方给的时效通常是 30 分钟往上，这里保守取 20 分钟。
  static const Duration urlTtl = Duration(minutes: 20);

  final Map<String, _ResolvedUrl> _cache = {};

  /// 确认取不到地址的歌（会员曲，且音源也没有）。
  ///
  /// 没有这份记录，每次起播都会为这些歌重跑一整套请求 —— 网易云那边实测
  /// 5 首就能把起播拖到四五秒。
  final Set<String> _unresolvable = {};

  /// 给第三方音源做匹配用的「歌名 歌手」和时长。
  ///
  /// 音源是按歌名搜、再比时长挑版本的，只给一个 mid 它对不上。
  final Map<String, (String, int)> _matchHints = {};

  Future<String?> resolveStreamUrl(String mid, {String? mediaMid}) async {
    final cached = _cache[mid];
    if (cached != null && !cached.isExpired) return cached.url;
    if (_unresolvable.contains(mid)) return null;
    try {
      var url = await QQApiClient.instance.songUrl(mid, mediaMid: mediaMid);
      // 官方给不出（会员曲）就问第三方音源。没配密钥时一个请求都不会发。
      final hint = _matchHints[mid];
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'tx',
        songId: mid,
        keyword: hint?.$1,
        durationMs: hint?.$2 ?? 0,
      );
      if (url == null) {
        _unresolvable.add(mid);
        return null;
      }
      final secure = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      _cache[mid] = _ResolvedUrl(secure, DateTime.now());
      return secure;
    } on QQApiException catch (e) {
      debugPrint('[QQ] 取播放地址失败 $mid：${e.message}');
      return null;
    }
  }

  /// 播放前筛掉取不到地址的歌，并把能播的地址预热进缓存。
  ///
  /// 为什么必须先筛：取不到地址时构建播放源那步会抛异常，而那发生在引擎
  /// 见到这首歌之前，于是播放器的错误恢复根本不会触发，整个队列卡在第一首
  /// 不动。网易云那边就是这么踩过来的。
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final pending = <SongEntity>[];
    for (final song in songs) {
      final mid = SongSource.decodeQQ(song.id);
      if (mid == null) continue;
      // 先记下匹配线索，后面走音源兜底时要用。
      _matchHints[mid] ??= (
        '${song.title} ${song.artistDisplayName}'.trim(),
        song.durationMs ?? 0,
      );
      if (_cache[mid]?.isExpired == false) continue;
      if (_unresolvable.contains(mid)) continue;
      pending.add(song);
    }

    if (pending.isNotEmpty) {
      // 并行取，但**限并发**：网易云那边一次并发一百个把第三方音源打成
      // 429，教训在前。
      const batch = 8;
      for (var i = 0; i < pending.length; i += batch) {
        final slice = pending.skip(i).take(batch);
        await Future.wait([
          for (final song in slice)
            resolveStreamUrl(
              SongSource.decodeQQ(song.id)!,
              mediaMid: song.audioSpec,
            ),
        ]);
      }
    }

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final mid = SongSource.decodeQQ(song.id);
      if (mid == null) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(mid)) {
        dropped++;
        continue;
      }
      playable.add(song);
    }
    debugPrint('[QQ] 队列 ${songs.length} 首：可播 ${playable.length}，跳过 $dropped');
    return playable;
  }

  void invalidate(String mid) => _cache.remove(mid);

  void clear() {
    _cache.clear();
    // 负缓存也要清：刚配好音源密钥时这些歌值得再试一次。
    _unresolvable.clear();
  }

  /// 播放时要带的请求头。QQ 的 CDN 会校验 Referer。
  static Map<String, String> streamHeaders() => const {
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  /// 把 QQ 的歌转成 App 内部的 [SongEntity]。
  ///
  /// `mediaMid` 借 [SongEntity.audioSpec] 存：取播放地址要用它拼文件名，
  /// 而为它单开一个数据库列不值当（见 [SongSource] 里关于不改 schema 的说明）。
  static SongEntity toSongEntity(QQSong song) {
    return SongEntity(
      id: SongSource.encodeQQ(song.mid),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      uri: 'https://y.qq.com/n/ryqq/songDetail/${song.mid}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs,
      coverId: song.coverUrl,
      audioSpec: song.mediaMid,
      format: 'mp3',
      isVip: song.payPlay,
    );
  }
}
