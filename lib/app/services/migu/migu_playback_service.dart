import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'migu_models.dart';

class _Resolved {
  _Resolved(this.url, this.at);
  final String url;
  final DateTime at;
  bool get isExpired =>
      DateTime.now().difference(at) > MiguPlaybackService.urlTtl;
}

class _Meta {
  const _Meta({
    required this.keyword,
    required this.durationMs,
    required this.contentId,
    required this.name,
    required this.singer,
  });
  final String keyword;
  final int durationMs;
  final String contentId;
  final String name;
  final String singer;
}

/// 咪咕播放地址解析与模型转换。
///
/// 取址走解灰链 `resolve(mg)` —— 聚合 / LX 的 mg 后端（回避、星海、listen-url、
/// zddyr…），免登录也能出地址。带上 name/singer，按歌名搜的后端也能命中。
///
/// 咪咕自家直连 `listenSong.do` 即便登录也只回「暂不提供试听地址」（要完整 SSO
/// 交换 + 签名，不划算），已弃用；登录态只用于显示 / 后续歌单收藏，不参与取址。
class MiguPlaybackService {
  MiguPlaybackService._();
  static final MiguPlaybackService instance = MiguPlaybackService._();

  static const Duration urlTtl = Duration(minutes: 45);

  final Map<String, _Resolved> _cache = {};
  final Set<String> _unresolvable = {};
  final Map<String, _Meta> _meta = {};
  final Map<String, Future<String?>> _inflight = {};

  static const int _maxConcurrent = 5;
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  Future<void> _acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _active--;
  }

  Future<String?> resolveStreamUrl(String copyrightId, {bool force = false}) async {
    if (!force) {
      final cached = _cache[copyrightId];
      if (cached != null && !cached.isExpired) return cached.url;
      if (_unresolvable.contains(copyrightId)) return null;
      final pending = _inflight[copyrightId];
      if (pending != null) return pending;
    }
    final future = _guarded(copyrightId);
    _inflight[copyrightId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(copyrightId);
    }
  }

  Future<String?> _guarded(String copyrightId) async {
    await _acquire();
    try {
      return await _resolveOnce(copyrightId);
    } finally {
      _release();
    }
  }

  Future<String?> _resolveOnce(String copyrightId) async {
    final meta = _meta[copyrightId];
    String? url;
    try {
      // 咪咕播放走解灰链（聚合 / LX 的 mg 后端）。自家直连 listenSong.do 即便
      // 登录也只回「暂不提供试听地址」（要完整 SSO 交换 + 签名，不划算），已弃用。
      // 带上 name/singer：有些 mg 后端按歌名+歌手搜，否则报「需要 name+singer」。
      url = await UnblockSourceService.instance.resolve(
        platform: 'mg',
        songId: copyrightId,
        keyword: meta?.keyword,
        durationMs: meta?.durationMs ?? 0,
        name: meta?.name,
        singer: meta?.singer,
      );
    } catch (e) {
      debugPrint('[Migu] 取址异常 $copyrightId：$e');
    }
    if (url == null || url.isEmpty) {
      if (!UnblockSourceService.instance.isRateLimited) {
        _unresolvable.add(copyrightId);
      }
      return null;
    }
    final secure = url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
    _cache[copyrightId] = _Resolved(secure, DateTime.now());
    return secure;
  }

  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final pending = <String>[];
    for (final song in songs) {
      final cid = SongSource.decodeMigu(song.id);
      if (cid == null) continue;
      _remember(song, cid);
      if (_cache[cid]?.isExpired == false) continue;
      if (_unresolvable.contains(cid)) continue;
      pending.add(cid);
    }
    await Future.wait([for (final cid in pending) resolveStreamUrl(cid)]);

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final cid = SongSource.decodeMigu(song.id);
      if (cid == null) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(cid)) {
        dropped++;
        continue;
      }
      playable.add(song);
    }
    debugPrint('[Migu] 队列 ${songs.length} 首：可播 ${playable.length}，跳过 $dropped');
    return playable;
  }

  void _remember(SongEntity song, String copyrightId) {
    if (_meta.containsKey(copyrightId)) return;
    final singer = song.artistDisplayName;
    _meta[copyrightId] = _Meta(
      keyword: '${song.title} $singer'.trim(),
      durationMs: song.durationMs ?? 0,
      // contentId 存在实体的 audioSpec 上（见 toSongEntity）。
      contentId: song.audioSpec ?? '',
      name: song.title,
      singer: singer,
    );
  }

  void invalidate(String copyrightId) {
    _cache.remove(copyrightId);
    _unresolvable.remove(copyrightId);
  }

  void clear() {
    _cache.clear();
    _unresolvable.clear();
    _inflight.clear();
  }

  static Map<String, String> streamHeaders() => const {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  static SongEntity toSongEntity(MiguSong song) {
    return SongEntity(
      id: SongSource.encodeMigu(song.copyrightId),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      uri: 'https://music.migu.cn/v3/music/song/${song.copyrightId}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs == 0 ? null : song.durationMs,
      coverId: song.coverUrl,
      // contentId 留给直连播放，lyricUrl 留给歌词页。
      audioSpec: song.contentId,
      codec: song.lyricUrl,
      format: 'mp3',
      isVip: song.isVip,
    );
  }
}
