import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'kugou_api_client.dart';
import 'kugou_models.dart';

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

  static const Duration urlTtl = Duration(minutes: 20);

  final Map<String, _ResolvedUrl> _cache = {};

  /// 确认拿不到地址的歌。没有这份记录，每次起播都会为它们重跑一整套请求。
  final Set<String> _unresolvable = {};

  /// 取址所需的 albumId / albumAudioId：从 SongEntity 里带过来。
  final Map<String, (String?, String?)> _albumRefs = {};

  Future<String?> resolveStreamUrl(String hash, {bool force = false}) async {
    if (!force) {
      final cached = _cache[hash];
      if (cached != null && !cached.isExpired) return cached.url;
      if (_unresolvable.contains(hash)) return null;
    }
    final refs = _albumRefs[hash];
    try {
      var url = await KugouApiClient.instance.songUrl(
        hash,
        albumId: refs?.$1,
        albumAudioId: refs?.$2,
      );
      // 官方给不出就问第三方音源。没配密钥时 resolve 直接返回 null。
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'kg',
        songId: hash,
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

  /// 取址要用的 album 引用存在 audioSpec / codec 两个既有字段里
  /// （见 SongSource 里关于不改数据库 schema 的说明）。
  void _rememberRefs(SongEntity song, String hash) {
    if (_albumRefs.containsKey(hash)) return;
    _albumRefs[hash] = (song.codec, song.audioSpec);
  }

  void invalidate(String hash) {
    _cache.remove(hash);
    _unresolvable.remove(hash);
  }

  void clear() {
    _cache.clear();
    _unresolvable.clear();
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
