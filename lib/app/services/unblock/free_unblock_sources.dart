import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 免费的灰色歌曲兜底音源，照 UnblockNeteaseMusic 的几个核心 provider 实现。
///
/// 和聆澜那种要密钥的音源是互补关系，不是替代：
/// - 聆澜命中率高、音质档位可选，但要花钱；
/// - 这三家不要密钥、不要账号，命中率和音质看运气。
///
/// 所以顺序是「先聆澜，没配或没命中再走这里」，见 [UnblockSourceService]。
///
/// 顺序有讲究：
/// 1. GD Studio —— 直接按**网易云原始 id** 取，对得最准，不会串成同名别的版本；
/// 2. 酷狗 —— 关键词搜索 + 时长匹配；
/// 3. 酷我 —— 同样是搜索匹配，但它的 convert_url 越来越常返回
///    「请在酷我音乐APP播放」的提示音，所以压到最后当兜底。
class FreeUnblockSources {
  FreeUnblockSources._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {'User-Agent': 'Mozilla/5.0'},
    ),
  );

  /// 逐个音源试，先拿到地址的赢。
  ///
  /// [keyword] 是「歌名 歌手」，[durationMs] 用来在搜索结果里挑对版本 ——
  /// 少了它很容易匹配到现场版、翻唱或者串烧。
  /// [neteaseId] 只有网易云的歌才有 —— GD Studio 按它查；酷狗和酷我这两家
  /// 本来就是「搜歌名再比时长」，跟来源是哪家无关。所以它是可选的：QQ 和
  /// 酷狗的歌照样能走后两家，之前把整条链按 platform=='wy' 拦掉是我堵死了
  /// 自己的退路。
  static Future<String?> resolve({
    int? neteaseId,
    required String keyword,
    required int durationMs,
  }) async {
    final label = neteaseId?.toString() ?? keyword;
    if (neteaseId != null) {
      final gd = await _gdStudio(neteaseId);
      if (gd != null) {
        debugPrint('[Unblock] GD Studio 命中 $label');
        return gd;
      }
    }
    if (keyword.trim().isEmpty) return null;

    final kugou = await _kugou(keyword, durationMs);
    if (kugou != null) {
      debugPrint('[Unblock] 酷狗命中 $label');
      return kugou;
    }
    final kuwo = await _kuwo(keyword, durationMs);
    if (kuwo != null) {
      debugPrint('[Unblock] 酷我命中 $label');
      return kuwo;
    }
    return null;
  }

  static Future<String?> _get(String url, {String? userAgent}) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: userAgent == null
            ? null
            : Options(headers: {'User-Agent': userAgent}),
      );
      if (response.statusCode != 200) return null;
      final body = response.data;
      return (body == null || body.isEmpty) ? null : body;
    } on DioException {
      return null;
    }
  }

  static Map<String, Object?>? _json(String? body) {
    if (body == null) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// UNM 的挑选规则：前 5 条里第一条时长差在 5 秒内的，都不满足就取第一条。
  static T? _selectMatch<T>(
    List<T> list,
    int durationMs,
    int Function(T) durationOf,
  ) {
    if (list.isEmpty) return null;
    for (final item in list.take(5)) {
      final d = durationOf(item);
      if (d > 0 && (d - durationMs).abs() < 5000) return item;
    }
    return list.first;
  }

  static String _https(String url) =>
      url.startsWith('http://') ? url.replaceFirst('http://', 'https://') : url;

  // ---- GD Studio（按网易云原始 id 取，最准）----

  static Future<String?> _gdStudio(int neteaseId) async {
    final body = await _get(
      'https://music-api.gdstudio.xyz/api.php'
      '?types=url&source=netease&id=$neteaseId&br=320',
    );
    final json = _json(body);
    if (json == null) return null;
    // br 为 0 表示这边也没货，此时 url 往往是个空串或占位。
    final br = json['br'];
    if (br is! int || br <= 0) return null;
    final url = json['url'];
    return (url is String && url.isNotEmpty) ? _https(url) : null;
  }

  // ---- 酷狗 ----

  static Future<String?> _kugou(String keyword, int durationMs) async {
    final query = Uri.encodeQueryComponent(keyword);
    final body = await _get(
      'https://mobilecdn.kugou.com/api/v3/search/song'
      '?format=json&keyword=$query&page=1&pagesize=10',
    );
    final json = _json(body);
    final data = json?['data'];
    if (data is! Map) return null;
    final info = data['info'];
    if (info is! List) return null;

    final songs = <({String hash, String albumId, int durationMs})>[];
    for (final item in info) {
      if (item is! Map) continue;
      final hash = item['hash'];
      if (hash is! String || hash.isEmpty) continue;
      final rawAlbum = item['album_id'];
      final seconds = item['duration'];
      songs.add((
        hash: hash,
        albumId: rawAlbum is String ? rawAlbum : '${rawAlbum ?? 0}',
        durationMs: (seconds is int ? seconds : 0) * 1000,
      ));
    }
    final match = _selectMatch(songs, durationMs, (s) => s.durationMs);
    if (match == null) return null;

    // 取流地址要一个 key：md5(hash + "kgcloudv2")。
    final key = md5.convert(utf8.encode('${match.hash}kgcloudv2')).toString();
    final trackBody = await _get(
      'https://trackercdn.kugou.com/i/v2/'
      '?key=$key&hash=${match.hash}&appid=1005&pid=2&cmd=25'
      '&behavior=play&album_id=${match.albumId}',
    );
    final trackJson = _json(trackBody);
    final urls = trackJson?['url'];
    if (urls is! List || urls.isEmpty) return null;
    final first = urls.first;
    return (first is String && first.isNotEmpty) ? _https(first) : null;
  }

  // ---- 酷我 ----

  static Future<String?> _kuwo(String keyword, int durationMs) async {
    final query = Uri.encodeQueryComponent(keyword);
    final body = await _get(
      'https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive'
      '&encoding=utf8&rformat=json&mobi=1&show_copyright_off=1'
      '&searchapi=6&all=$query',
    );
    final json = _json(body);
    final content = json?['content'];
    if (content is! List || content.length < 2) return null;
    final page = content[1];
    if (page is! Map) return null;
    final musicpage = page['musicpage'];
    if (musicpage is! Map) return null;
    final abslist = musicpage['abslist'];
    if (abslist is! List) return null;

    final songs = <({String rid, int durationMs})>[];
    for (final item in abslist) {
      if (item is! Map) continue;
      final musicrid = item['MUSICRID'];
      if (musicrid is! String) continue;
      final rid = musicrid.split('_').last;
      if (rid.isEmpty) continue;
      final raw = item['DURATION'];
      final seconds = raw is int ? raw : int.tryParse('${raw ?? ''}') ?? 0;
      songs.add((rid: rid, durationMs: seconds * 1000));
    }
    final match = _selectMatch(songs, durationMs, (s) => s.durationMs);
    if (match == null) return null;

    // 这个接口返回的是**纯文本**地址，不是 JSON；换成浏览器 UA 会拿到空串。
    final text = await _get(
      'https://antiserver.kuwo.cn/anti.s'
      '?type=convert_url&format=mp3&response=url&rid=MUSIC_${match.rid}',
      userAgent: 'okhttp/3.10.0',
    );
    if (text == null) return null;
    final found = RegExp(r'http[^\s"]+').firstMatch(text);
    final url = found?.group(0);
    if (url == null || url.isEmpty) return null;
    final secure = _https(url);
    return await _looksLikeRealAudio(secure, durationMs) ? secure : null;
  }

  /// 拦下酷我的「请到酷我音乐APP收听」提示音。
  ///
  /// 那段提示音是一个**正常可下载的 mp3**，地址、状态码都挑不出毛病 ——
  /// 只有时长不对：十几秒对上一首四分钟的歌。之前没有这道检查，它就被当成
  /// 有效地址塞进队列，播放器打开后放几秒提示音就跳下一首，表现是「歌全都
  /// 自动跳过」，很难看出是音源的问题。
  ///
  /// 用体积反推时长：按 128kbps 算，每秒约 16000 字节。比应有时长的一半还
  /// 短就判定是提示音。时长未知时退一步用绝对下限（300KB ≈ 19 秒）。
  static Future<bool> _looksLikeRealAudio(String url, int durationMs) async {
    try {
      final res = await _dio.head<void>(url);
      final raw = res.headers.value('content-length');
      final bytes = int.tryParse(raw ?? '');
      // 拿不到长度就别拦：宁可放过，也好过把能播的歌误杀。
      if (bytes == null || bytes <= 0) return true;
      const bytesPerSecond = 16000;
      if (durationMs > 0) {
        final expected = durationMs ~/ 1000 * bytesPerSecond;
        if (bytes < expected ~/ 2) {
          debugPrint(
            '[Unblock] 酷我返回的疑似提示音（${(bytes / 1024).round()}KB，'
            '应有 ${(expected / 1024).round()}KB），丢弃',
          );
          return false;
        }
        return true;
      }
      if (bytes < 300 * 1024) {
        debugPrint('[Unblock] 酷我返回的音频只有 ${(bytes / 1024).round()}KB，丢弃');
        return false;
      }
      return true;
    } catch (_) {
      // 探测本身失败不算证据，放行。
      return true;
    }
  }
}
