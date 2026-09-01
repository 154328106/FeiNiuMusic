import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/unblock_source.dart';
import 'netease_api_client.dart';
import 'netease_models.dart';

/// 一条已解析的网易云播放地址及其有效期。
class _ResolvedUrl {
  _ResolvedUrl(this.url, this.resolvedAt);

  final String url;
  final DateTime resolvedAt;

  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > NetEasePlaybackService.urlTtl;
}

/// 网易云歌曲的播放地址解析与模型转换。
///
/// 与飞牛最大的不同：**飞牛的流地址是稳定的**（`/track/stream?guid=…`，凭
/// Cookie 认证，可以直接存进数据库反复用），**网易云的是带签名和时效的临时
/// 直链**，存进数据库过几小时就 403。所以网易云歌曲的 `SongEntity.uri` 只是
/// 一个「上次拿到的地址」占位，真正播放前必须调 [resolveStreamUrl] 重新取。
class NetEasePlaybackService {
  NetEasePlaybackService._();

  static final NetEasePlaybackService instance = NetEasePlaybackService._();

  /// 直链有效期。网易云实际给的时效通常更长，这里保守取 20 分钟，
  /// 避免长队列播到后面时地址已过期。
  static const Duration urlTtl = Duration(minutes: 20);

  final Map<int, _ResolvedUrl> _cache = {};
  final Map<int, Future<String?>> _inflight = {};

  /// 确认取不到地址的歌（下架 / 无版权，且音源也没有）。
  ///
  /// 没有这份记录，每次起播都会把这些歌重新走一遍完整流程：eapi → weapi
  /// 兜底 → 降级 standard → 逐个问音源。实测 5 首这样的歌就要 4.4 秒，
  /// 表现为「点收藏要等五秒才出声，切下一首还是等五秒」。
  final Set<int> _unresolvable = {};

  /// 当前音质档位。免费账号拿不到 lossless 会自动降级。
  String level = 'exhigh';

  /// 解析某首网易云歌曲的可播放直链。
  ///
  /// 返回 null 表示拿不到地址——灰色歌曲、无版权、或未登录的 VIP 曲目。
  /// 调用方应把这首跳过而不是反复重试。
  Future<String?> resolveStreamUrl(int neteaseId, {bool force = false}) async {
    if (!force) {
      final cached = _cache[neteaseId];
      if (cached != null && !cached.isExpired) return cached.url;
    }

    // 同一首歌并发请求合并，避免切歌抖动时打出多个请求。
    final inflight = _inflight[neteaseId];
    if (inflight != null) return inflight;

    final future = _fetch(neteaseId);
    _inflight[neteaseId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(neteaseId);
    }
  }

  Future<String?> _fetch(int neteaseId) async {
    // 已确认取不到的，直接返回，不再走一整套请求。
    if (_unresolvable.contains(neteaseId)) return null;
    try {
      final result = await NetEaseApiClient.instance.songUrls([
        neteaseId,
      ], level: level);
      final info = result[neteaseId];
      var url = info?.url;

      // 官方给不出地址（灰色/无版权/需要会员），或只给了试听片段 → 问第三方
      // 音源。没配密钥时 resolve 直接返回 null，一个请求都不会发。
      final needsUnblock = url == null || (info?.freeTrial ?? false);
      if (needsUnblock) {
        final unblocked = await UnblockSourceService.instance.resolve(
          platform: 'wy',
          songId: '$neteaseId',
        );
        if (unblocked != null) {
          debugPrint('[NetEase] $neteaseId 由第三方音源提供地址');
          url = unblocked;
        }
      }

      if (url == null) {
        _unresolvable.add(neteaseId);
        debugPrint('[NetEase] $neteaseId 无可用播放地址（灰色/无版权/需要会员）');
        return null;
      }
      if ((info?.freeTrial ?? false) && identical(url, info?.url)) {
        debugPrint('[NetEase] $neteaseId 只返回了试听片段');
      }
      // 网易云返回的直链有 http 和 https 两种，统一升到 https：
      // Android 9+ 默认禁止明文 HTTP，http 直链会被系统拦掉。
      final secure = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      _cache[neteaseId] = _ResolvedUrl(secure, DateTime.now());
      return secure;
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEase] 取播放地址失败 $neteaseId：${e.message}');
      return null;
    }
  }

  /// 播放前筛掉取不到地址的歌，并把能播的地址预热进缓存。
  ///
  /// 为什么必须先筛：取不到地址时 `_sourceForSong` 会抛异常，而那发生在
  /// **构建播放源**阶段 —— 播放器的错误恢复挂在引擎错误流上，这时引擎还没
  /// 见到这首歌，于是既不报错也不跳过，整个队列就卡在第一首不动。收藏夹里
  /// 存着几首下架歌就足以让「播放收藏」完全没反应。
  ///
  /// 取地址的接口支持批量，所以整队只要一次请求；顺带把结果写进缓存，
  /// 真正播放时不用再问一遍。
  Future<List<SongEntity>> prepareQueue(List<SongEntity> songs) async {
    final ids = <int>[];
    for (final song in songs) {
      final id = song.neteaseId;
      if (id == null) continue;
      // 已缓存地址的、以及已确认取不到的，都不用再问。
      if (_cache[id]?.isExpired == false) continue;
      if (_unresolvable.contains(id)) continue;
      ids.add(id);
    }
    if (ids.isEmpty) {
      // 全部有结论了，直接按结论过滤，一个网络请求都不发。
      return songs
          .where((s) => !_unresolvable.contains(s.neteaseId ?? -1))
          .toList();
    }

    Map<int, NetEaseSongUrl> result;
    try {
      result = await NetEaseApiClient.instance.songUrls(ids, level: level);
      // 曾经在这里加过「全空就降级 standard 重试」。实测无用：eapi 本身
      // 工作正常（48/54 有地址），取不到的那几首是真下架，换音质也一样是空。
      // 留着只会让每次起播多打一轮请求，去掉。
    } on NetEaseApiException catch (e) {
      // 批量失败就不要在这里拦人，交给播放时逐首解析。
      debugPrint('[NetEase] 批量取地址失败，跳过预筛：${e.message}');
      return songs;
    }

    // 官方给不出地址的，统一交给音源。并行问，但要限流 —— 上一版直接
    // Future.wait 把整队一次全发出去，100 首的队列瞬间打出 100 个请求，
    // 聆澜整片回 429，等于白问一轮。分批走，每批之间喘一口。
    final needUnblock = <int>[
      for (final id in ids)
        if (result[id]?.url == null || (result[id]?.freeTrial ?? false)) id,
    ];
    // 免费兜底音源（酷狗/酷我）是按关键词搜的，得把歌名歌手和时长递过去，
    // 否则很容易匹配到现场版或翻唱。
    final byId = <int, SongEntity>{
      for (final song in songs)
        if (song.neteaseId != null) song.neteaseId!: song,
    };
    final unblocked = await _resolveUnblocked(needUnblock, byId);

    final playable = <SongEntity>[];
    var dropped = 0;
    for (final song in songs) {
      final id = song.neteaseId;
      if (id == null) {
        playable.add(song);
        continue;
      }
      final cached = _cache[id];
      if (cached != null && !cached.isExpired) {
        playable.add(song);
        continue;
      }
      if (_unresolvable.contains(id)) {
        dropped++;
        continue;
      }
      final url = result[id]?.freeTrial == true
          ? (unblocked[id] ?? result[id]?.url)
          : (result[id]?.url ?? unblocked[id]);
      if (url == null) {
        // 官方和音源都没有 → 记下来，之后不再为它发请求。
        _unresolvable.add(id);
        dropped++;
        continue;
      }
      final secure = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      _cache[id] = _ResolvedUrl(secure, DateTime.now());
      playable.add(song);
    }
    // 官方能给出地址的比例是关键诊断：几乎全给不出 → 多半是登录态没生效；
    // 只有零星几首给不出 → 那几首本来就下架了。
    final official = result.values.where((e) => e.url != null).length;
    debugPrint(
      '[NetEase] 队列 ${songs.length} 首：本次问了 ${ids.length} 首，'
      '官方 $official 首有地址，可播 ${playable.length} 首，跳过 $dropped 首',
    );
    return playable;
  }

  /// 一批一批地问音源，别一次全发出去。
  ///
  /// [_unblockBatchSize] 是拍的：小到不会触发限流，大到还留着并行的好处。
  /// 批与批之间停一下，让对面的令牌桶回一点。
  static const int _unblockBatchSize = 5;
  static const Duration _unblockBatchGap = Duration(milliseconds: 250);

  Future<Map<int, String>> _resolveUnblocked(
    List<int> ids,
    Map<int, SongEntity> byId,
  ) async {
    final out = <int, String>{};
    for (var start = 0; start < ids.length; start += _unblockBatchSize) {
      final end = (start + _unblockBatchSize).clamp(0, ids.length);
      final batch = ids.sublist(start, end);
      final resolved = await Future.wait([
        for (final id in batch)
          UnblockSourceService.instance.resolve(
            platform: 'wy',
            songId: '$id',
            keyword: _searchKeyword(byId[id]),
            durationMs: byId[id]?.durationMs ?? 0,
          ),
      ]);
      for (var i = 0; i < batch.length; i++) {
        final url = resolved[i];
        if (url != null) out[batch[i]] = url;
      }
      if (end < ids.length) await Future<void>.delayed(_unblockBatchGap);
    }
    return out;
  }

  /// 「歌名 歌手」，给按关键词搜索的兜底音源用。
  static String _searchKeyword(SongEntity? song) {
    if (song == null) return '';
    final artist = song.artistDisplayName;
    return artist.isEmpty ? song.title : '${song.title} $artist';
  }

  /// 丢弃某首歌的地址缓存（播放失败后重取用）。
  void invalidate(int neteaseId) => _cache.remove(neteaseId);

  void clear() {
    _cache.clear();
    // 负缓存也要清：换了账号、或者刚配好音源密钥，这些歌值得再试一次。
    _unresolvable.clear();
  }

  /// 播放网易云歌曲时要带的请求头。
  ///
  /// 音频 CDN 会校验 Referer，缺了会 403。注意**不能带飞牛的 Cookie**。
  static Map<String, String> streamHeaders() => const {
    'Referer': 'https://music.163.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  /// 把网易云搜索结果转成 App 内部的 [SongEntity]。
  ///
  /// `artist` / `album` 按仓库既有约定写成 JSON（飞牛那边存的是带 guid 的
  /// JSON），这样 `artistDisplayName` / `albumDisplayName` 以及直接
  /// `jsonDecode` 的消费方都走正常路径，不必依赖解析失败的兜底分支。
  /// 网易云没有飞牛的 guid 概念，guid 一律留空串。
  static SongEntity toSongEntity(NetEaseSong song, {String? resolvedUrl}) {
    return SongEntity(
      id: SongSource.encodeNetease(song.id),
      title: song.name,
      artist: jsonEncode([
        for (final name in song.artists.split(' / ').where((n) => n.isNotEmpty))
          {'guid': '', 'name': name},
      ]),
      album: jsonEncode({'guid': '', 'name': song.album}),
      // 临时直链，播放前会被 resolveStreamUrl 重新解析。存一份是为了让
      // player_service 里「uri 非空才算可播」的既有判断成立。
      uri: resolvedUrl ?? 'https://music.163.com/song?id=${song.id}',
      headersJson: jsonEncode(streamHeaders()),
      durationMs: song.durationMs,
      // 网易云封面是公网直链，直接放进 coverId；ArtworkWidget 按来源分流，
      // 认出是 http 就当完整 URL 用，不去拼飞牛的 /static/cover。
      coverId: song.coverUrl,
      format: 'mp3',
    );
  }
}
