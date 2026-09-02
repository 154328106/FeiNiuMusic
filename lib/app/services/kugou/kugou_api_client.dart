import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'kugou_models.dart';

class KugouApiException implements Exception {
  KugouApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      'KugouApiException($message${code == null ? '' : ', code=$code'})';
}

/// 酷狗音乐接口。
///
/// 三家里最省事的一家：没有加密，只有一个 MD5 签名，而且**取播放地址时
/// 会明确返回 status / error_code** —— QQ 那边没有这个，才会出现「给了地址
/// 但是死链、显示可播却全哑」。这里能按状态码把没权限的歌真正筛掉。
///
/// 接口全走移动站 / CDN 的纯 GET 老接口（参考 Beans-Music 的
/// KugouMusicAPI.swift），不需要登录。
class KugouApiClient {
  KugouApiClient._();

  static final KugouApiClient instance = KugouApiClient._();

  /// 取播放地址的签名盐，以及客户端标识。照抄官方安卓端。
  static const String _playSalt = 'kgcloudv2';
  static const String _appid = '1005';
  static const String _clientver = '20489';

  static const String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 设备 mid：签名的一部分。酷狗只要求是个稳定的 32 位十六进制串。
  static final String _mid = md5
      .convert(utf8.encode('feiniu-${Random().nextInt(1 << 32)}'))
      .toString();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {'User-Agent': _browserUa},
    ),
  );

  Future<Map<String, dynamic>> _getJson(String url, {String? ua}) async {
    final Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: ua == null ? null : Options(headers: {'User-Agent': ua}),
      );
    } on DioException catch (e) {
      throw KugouApiException('网络请求失败：${e.message ?? e.type.name}');
    }
    if (response.statusCode != 200) {
      throw KugouApiException(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    // 取址接口会用 <!--KG_TAG_RES_START--> 把 JSON 夹起来，先剥掉。
    var body = (response.data ?? '')
        .replaceAll('<!--KG_TAG_RES_START-->', '')
        .replaceAll('<!--KG_TAG_RES_END-->', '')
        .trim();
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start > 0 && end > start) body = body.substring(start, end + 1);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw KugouApiException('响应格式异常');
    }
    return decoded;
  }

  static String _md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  // ---------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------

  /// 搜索歌曲。走移动 CDN 的老接口：免登录、不用签名、字段稳定。
  Future<List<KugouSong>> searchSongs(String keyword, {int limit = 30}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final json = await _getJson(
      'https://mobilecdn.kugou.com/api/v3/search/song'
      '?format=json&keyword=${Uri.encodeQueryComponent(query)}'
      '&page=1&pagesize=$limit',
    );
    final info = _at(json, ['data', 'info']) as List?;
    return _toSongs(info);
  }

  // ---------------------------------------------------------------------
  // 榜单 / 歌单
  // ---------------------------------------------------------------------

  /// 排行榜列表。
  Future<List<KugouPlaylist>> rankList({int limit = 12}) async {
    final json = await _getJson('https://m.kugou.com/rank/list?json=true');
    final list = _at(json, ['rank', 'list']) as List? ?? const [];
    final result = <KugouPlaylist>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final id = (item['rankid'] ?? item['id']) as num?;
      final name = (item['rankname'] ?? item['name'])?.toString() ?? '';
      if (id == null || name.isEmpty) continue;
      var cover = (item['imgurl'] ?? item['banner7url'])?.toString();
      if (cover != null) cover = cover.replaceAll('{size}', '400');
      result.add(
        KugouPlaylist(
          id: id.toInt(),
          name: name,
          coverUrl: (cover == null || cover.isEmpty) ? null : cover,
          trackCount: 0,
        ),
      );
      if (result.length >= limit) break;
    }
    return result;
  }

  /// 榜单内的歌。
  Future<List<KugouSong>> rankSongs(int rankId, {int limit = 60}) async {
    // 一页只有 30 首，翻到够为止（榜单本身也就几页）。
    final seen = <String>{};
    final songs = <KugouSong>[];
    for (var page = 1; page <= 4 && songs.length < limit; page++) {
      final json = await _getJson(
        'https://m.kugou.com/rank/info?rankid=$rankId&page=$page&json=true',
      );
      final rows = _at(json, ['songs', 'list']) as List?;
      final batch = _toSongs(rows);
      if (batch.isEmpty) break;
      for (final song in batch) {
        if (seen.add(song.hash)) songs.add(song);
      }
    }
    return songs.length <= limit ? songs : songs.sublist(0, limit);
  }

  /// 首页内容：拿几个热门榜拼一份。
  ///
  /// 8888 是酷狗 TOP500，6666 是飙升榜，31308 是新歌榜 —— 都不需要登录。
  Future<List<KugouSong>> recommendSongs({int limit = 60}) async {
    final seen = <String>{};
    final songs = <KugouSong>[];
    for (final rankId in const [8888, 6666, 31308]) {
      try {
        for (final song in await rankSongs(rankId, limit: 30)) {
          if (seen.add(song.hash)) songs.add(song);
        }
      } on KugouApiException catch (e) {
        debugPrint('[Kugou] 榜单 $rankId 读取失败：${e.message}');
      }
    }
    // 按当天日期做种子：每天换一批，同一天内顺序固定。顺序不稳的话，
    // 点歌时重新拉的那份和屏幕上显示的对不上 —— QQ 那边踩过。
    final now = DateTime.now();
    songs.shuffle(Random(now.year * 10000 + now.month * 100 + now.day));
    return songs.length <= limit ? songs : songs.sublist(0, limit);
  }

  // ---------------------------------------------------------------------
  // 播放地址 / 歌词
  // ---------------------------------------------------------------------

  /// 取播放地址。
  ///
  /// 返回 null 表示这首拿不到 —— 而且是**真的**拿不到：这个接口会给
  /// `status` 和 `error_code`，不像 QQ 那样发一个打不开的死链回来。
  Future<String?> songUrl(
    String hash, {
    String? albumId,
    String? albumAudioId,
  }) async {
    final h = hash.toUpperCase();
    final key = _md5Hex('$h$_playSalt$_appid${_mid}0');
    final params = <String, String>{
      'cmd': '26',
      'hash': h,
      'behavior': 'play',
      'appid': _appid,
      'pid': '2',
      'mid': _mid,
      'userid': '0',
      'version': _clientver,
      'vipType': '0',
      'token': '0',
      'key': key,
      if (albumAudioId != null && albumAudioId.isNotEmpty)
        'album_audio_id': albumAudioId,
      if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final json = await _getJson('https://trackercdn.kugou.com/i/v2/?$query');

    final status = (json['status'] as num?)?.toInt() ?? 0;
    final code =
        (json['error_code'] ?? json['errcode'] ?? json['code']) as num?;
    final url = _firstUrl([
      json['play_url'],
      json['url'],
      json['play_backup_url'],
      json['backup_url'],
    ]);
    if (url == null) {
      debugPrint('[Kugou] $h 无地址：status=$status code=${code?.toInt()}');
      return null;
    }
    return url;
  }

  /// 歌词。两步：先按 hash 搜到 lyric id + accesskey，再下载。
  Future<String?> lyric(String hash, {int durationMs = 0}) async {
    final search = await _getJson(
      'https://krcs.kugou.com/search?ver=1&man=yes&client=mobi'
      '&hash=${Uri.encodeQueryComponent(hash)}&duration=$durationMs',
    );
    final candidates = search['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    final first = candidates.whereType<Map<String, dynamic>>().firstOrNull;
    final id = first?['id']?.toString();
    final accessKey = first?['accesskey']?.toString();
    if (id == null || accessKey == null) return null;

    final download = await _getJson(
      'https://lyrics.kugou.com/download?ver=1&client=pc&fmt=lrc'
      '&charset=utf8&id=$id&accesskey=$accessKey',
    );
    final content = download['content'] as String?;
    if (content == null || content.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(content));
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------

  /// 从若干候选字段里挑出第一个能用的地址。
  ///
  /// 酷狗的 `url` 字段**是个数组**（主备两个 CDN），直接 `.toString()` 会得到
  /// `[http://a.mp3, http://b.mp3]` 这么一串 —— 播放器把它当成文件路径，报
  /// 「Cannot open file .../tmp/[http://…, http://…]: No such file」。这就是
  /// 「显示可播 60/60 却一首都开不了」的真正原因，跟权限无关。
  static String? _firstUrl(List<Object?> candidates) {
    for (final value in candidates) {
      if (value is String && value.isNotEmpty) return value;
      if (value is List) {
        for (final item in value) {
          if (item is String && item.isNotEmpty) return item;
        }
      }
    }
    return null;
  }

  static Object? _at(Map<String, dynamic> root, List<String> path) {
    Object? node = root;
    for (final key in path) {
      if (node is Map && node.containsKey(key)) {
        node = node[key];
      } else {
        return null;
      }
    }
    return node;
  }

  static List<KugouSong> _toSongs(List? list) {
    if (list == null) return const [];
    final songs = <KugouSong>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final song = KugouSong.fromJson(item);
      if (song != null) songs.add(song);
    }
    return songs;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
