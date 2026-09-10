import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import '../unblock/kugou_public_sources.dart';
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

  /// 正在解析中的 mid → 同一个 Future。
  ///
  /// 缓存只在**拿到结果之后**才挡得住重复请求。真机日志里首页缓存命中后又
  /// 起了一次后台刷新，两个 prepareQueue 并发跑同一批歌，同一首被解析两遍
  /// （`队列 25 首` 打了两次）—— 等于对着公益服务打双份，而作者明说了
  /// 「切勿短时间批量」。让后来者搭前一个的车。
  final Map<String, Future<String?>> _inFlight = {};

  /// 确认取不到地址的歌（会员曲，且音源也没有）。
  ///
  /// 没有这份记录，每次起播都会为这些歌重跑一整套请求 —— 网易云那边实测
  /// 5 首就能把起播拖到四五秒。
  final Set<String> _unresolvable = {};

  /// 给第三方音源做匹配用的线索。
  ///
  /// - [keyword]「歌名 歌手」：按歌名搜的那几家要用，只给 mid 它对不上；
  /// - [title] 纯歌名：星海要的是这个（它的 410 明说「需提供 name」）；
  /// - [durationMs] 时长：搜出来一堆版本时靠它挑对的那个。
  final Map<String, ({String keyword, String title, int durationMs})>
  _matchHints = {};

  /// 只用来验官方地址能不能打开，超时给短一点：这一步是卡在起播路径上的。
  static final Dio _probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      validateStatus: (_) => true,
      followRedirects: true,
    ),
  );

  /// 官方地址，但**验过能打开**才返回。
  ///
  /// QQ 会返回一个打不开的 purl，而且接口本身不给状态码 —— 起播前分辨不出
  /// 真假，预筛形同虚设，表现成「队列显示可播 23 首、一首都放不出声」。
  /// 这就是当初把扣扣音乐从源列表里摘掉的直接原因。现在拿 1 字节的 Range
  /// 请求探一下：能开才算数。
  ///
  /// 用 Range 而不是 HEAD：QQ 的 CDN 对 HEAD 的支持不稳，Range 更接近播放器
  /// 真正会发的请求。
  Future<String?> _verifiedOfficialUrl(String mid, String? mediaMid) async {
    final url = await QQApiClient.instance.songUrl(mid, mediaMid: mediaMid);
    if (url == null) return null;
    try {
      final res = await _probeDio.get<void>(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-1'},
          responseType: ResponseType.stream,
        ),
      );
      final code = res.statusCode ?? 0;
      if (code == 200 || code == 206) return url;
      debugPrint('[QQ] $mid 官方地址打不开（HTTP $code），丢弃');
      return null;
    } catch (e) {
      debugPrint('[QQ] $mid 官方地址探测失败，丢弃：$e');
      return null;
    }
  }

  Future<String?> resolveStreamUrl(String mid, {String? mediaMid}) {
    final cached = _cache[mid];
    if (cached != null && !cached.isExpired) return Future.value(cached.url);
    if (_unresolvable.contains(mid)) return Future.value(null);
    final running = _inFlight[mid];
    if (running != null) return running;
    final future = _resolveStreamUrl(mid, mediaMid: mediaMid);
    _inFlight[mid] = future;
    return future.whenComplete(() => _inFlight.remove(mid));
  }

  Future<String?> _resolveStreamUrl(String mid, {String? mediaMid}) async {
    try {
      // 顺序是「公益源 → 官方 → 其余音源」，和网易云/酷狗反着来，两个理由：
      //
      // 1. 官方只给 128k（320k 要绿钻，硬要会拿到打不开的假地址，见
      //    QQApiClient.songUrl 那段）。而 haitangw 用**同一个 songmid** 给的
      //    是 QQ 自己的 flac：真机实测 5 首，文件名是 QQ 的 F000{media_mid}
      //    格式，按 QQ 报的时长反推码率落在 1647~1879kbps（24bit Hi-Res）与
      //    960kbps（标准 flac），比值集中说明配的就是那首歌。
      // 2. 官方那个假地址正是 2026-09-02 把扣扣音乐整个摘掉的原因，先问公益
      //    源能绕开大部分。
      final hint = _matchHints[mid];
      var url = await KugouPublicSources.resolve(
        mid,
        source: 'tx',
        // 不让它「排队太久就让路」：让出去下一站是 128k，白白降一档音质。
        allowBail: false,
        name: hint?.title,
      );
      url ??= await _verifiedOfficialUrl(mid, mediaMid);
      // 还没有就走完整音源链。公益源上面已经问过了，别再打一遍。
      url ??= await UnblockSourceService.instance.resolve(
        platform: 'tx',
        songId: mid,
        keyword: hint?.keyword,
        durationMs: hint?.durationMs ?? 0,
        skipPublicSources: true,
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
        keyword: '${song.title} ${song.artistDisplayName}'.trim(),
        title: song.title,
        durationMs: song.durationMs ?? 0,
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
