import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'kuwo_models.dart';

class KuwoApiException implements Exception {
  KuwoApiException(this.message);
  final String message;
  @override
  String toString() => 'KuwoApiException: $message';
}

/// 酷我音乐 API 客户端（MVP：搜索 + 榜单）。
///
/// 两条通道：
/// - www 接口（`www.kuwo.cn/api/www/...`）：返回干净 JSON（含完整封面 http
///   地址）。有一道很轻的反爬——请求头 `csrf` 必须等于 Cookie 的 `kw_token`，
///   值随便填、两者一致即可。它常以 `text/plain` 返回 JSON，所以**自己
///   jsonDecode**，不依赖 dio 按 content-type 自动解析（否则 data 是 String，
///   取 code 永远 null）。
/// - search.kuwo.cn/r.s：老的移动搜索接口，无需 csrf，字段是大写
///   （NAME/ARTIST/MUSICRID…）。www 不灵时兜底。
class KuwoApiClient {
  KuwoApiClient._();
  static final KuwoApiClient instance = KuwoApiClient._();

  // 任意字符串，只要 header csrf 和 cookie kw_token 一致即可。
  static final String _token = () {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  }();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      // 自己 decode，接口经常以 text/plain 回 JSON。
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  // 服务器真正下发过的 kw_token。自造的 token 服务器不认，必须先访问一次
  // 首页拿到 Set-Cookie 里的真 token。
  String? _realToken;
  Future<void>? _tokenInflight;

  Future<void> _ensureToken() {
    if (_realToken != null) return Future.value();
    return _tokenInflight ??= () async {
      try {
        final res = await _dio.get<dynamic>(
          'https://www.kuwo.cn/',
          options: Options(
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            },
          ),
        );
        final cookies = res.headers.map['set-cookie'] ?? const [];
        for (final c in cookies) {
          final m = RegExp(r'kw_token=([^;]+)').firstMatch(c);
          if (m != null) {
            _realToken = m.group(1);
            break;
          }
        }
      } catch (e) {
        debugPrint('[Kuwo] 取 kw_token 失败：$e');
      } finally {
        _tokenInflight = null;
      }
    }();
  }

  String get _effToken => _realToken ?? _token;

  Map<String, String> get _wwwHeaders => {
    'csrf': _effToken,
    'Cookie': 'kw_token=$_effToken',
    'Referer': 'https://www.kuwo.cn/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  String _reqId() {
    final r = Random();
    return List.generate(32, (_) => '0123456789abcdef'[r.nextInt(16)]).join();
  }

  dynamic _decode(dynamic data) {
    if (data is Map || data is List) return data;
    if (data is String && data.isNotEmpty) {
      try {
        return jsonDecode(data);
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, dynamic>?> _www(
    String path,
    Map<String, dynamic> params,
  ) async {
    await _ensureToken();
    final res = await _dio.get<dynamic>(
      'https://www.kuwo.cn$path',
      queryParameters: {...params, 'httpsStatus': 1, 'reqId': _reqId()},
      options: Options(headers: _wwwHeaders),
    );
    final json = _decode(res.data);
    if (json is Map && json['code'] == 200 && json['data'] is Map) {
      return (json['data'] as Map).cast<String, dynamic>();
    }
    final head = res.data is String ? (res.data as String) : jsonEncode(res.data);
    debugPrint('[Kuwo] www $path status=${res.statusCode} '
        'body=${head.length > 200 ? head.substring(0, 200) : head}');
    return null;
  }

  /// 关键字搜歌：先 www，不灵再回落 r.s。
  Future<List<KuwoSong>> search(String keyword, {int limit = 30}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    try {
      final data = await _www('/api/www/search/searchMusicBykeyWord', {
        'key': kw,
        'pn': 1,
        'rn': limit,
      });
      final list = _parseList(data?['list']);
      if (list.isNotEmpty) return list;
    } catch (e) {
      debugPrint('[Kuwo] www 搜索异常：$e');
    }
    // 兜底：search.kuwo.cn/r.s
    try {
      return await _searchRs(kw, limit);
    } catch (e) {
      debugPrint('[Kuwo] r.s 搜索异常：$e');
      return const [];
    }
  }

  /// 榜单（首页用）。bangId 93=飙升榜、16=热歌榜、158=新歌榜。
  ///
  /// 走 www（带完整封面）；www 不通返回空，上层回落带封面的搜索。
  /// 不用 kbangserver —— 它虽免 csrf，但返回里**没有封面字段**，首页会一片灰。
  Future<List<KuwoSong>> rank({int bangId = 93, int limit = 30}) async {
    try {
      final data = await _www('/api/www/bang/bang/musicList', {
        'bangId': bangId,
        'pn': 1,
        'rn': limit,
      });
      return _parseList(data?['musicList']);
    } catch (e) {
      debugPrint('[Kuwo] 榜单异常：$e');
      return const [];
    }
  }

  /// 歌词（LRC）。m.kuwo.cn 的 songinfoandlrc 偶发返回 data:null / status 301
  /// （限流，连大热歌都会），重试一次大多能救。
  Future<String?> lyric(String rid) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final lrc = await _lyricOnce(rid);
      if (lrc != null) return lrc;
      await Future.delayed(const Duration(milliseconds: 450));
    }
    return null;
  }

  Future<String?> _lyricOnce(String rid) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://m.kuwo.cn/newh5/singles/songinfoandlrc',
        queryParameters: {'musicId': rid, 'httpsStatus': 1},
        options: Options(
          headers: {
            'Referer': 'https://m.kuwo.cn/',
            'Cookie': 'kw_token=$_token',
            'csrf': _token,
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
          },
        ),
      );
      final json = _decode(res.data);
      final lrclist = (json is Map && json['data'] is Map)
          ? (json['data'] as Map)['lrclist']
          : null;
      if (lrclist is! List || lrclist.isEmpty) return null;
      final buf = StringBuffer();
      for (final line in lrclist) {
        if (line is! Map) continue;
        final t = double.tryParse('${line['time'] ?? ''}') ?? -1;
        final text = (line['lineLyric'] ?? '').toString();
        if (t < 0) continue;
        final m = (t ~/ 60).toString().padLeft(2, '0');
        final s = (t % 60).toStringAsFixed(2).padLeft(5, '0');
        buf.writeln('[$m:$s]$text');
      }
      final lrc = buf.toString().trim();
      return lrc.isEmpty ? null : lrc;
    } catch (e) {
      debugPrint('[Kuwo] 歌词异常：$e');
      return null;
    }
  }

  // ---- r.s 兜底搜索 ----

  Future<List<KuwoSong>> _searchRs(String keyword, int limit) async {
    final query = Uri.encodeQueryComponent(keyword);
    final res = await _dio.get<dynamic>(
      'https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive'
      '&encoding=utf8&rformat=json&mobi=1&show_copyright_off=1'
      '&searchapi=6&pn=0&rn=$limit&all=$query',
    );
    final json = _decode(res.data);
    if (json is! Map) return const [];
    final content = json['content'];
    if (content is! List || content.length < 2) return const [];
    final page = content[1];
    final abslist = (page is Map ? page['musicpage'] : null);
    final list = (abslist is Map ? abslist['abslist'] : null);
    if (list is! List) return const [];
    final out = <KuwoSong>[];
    for (final item in list) {
      if (item is! Map) continue;
      final ridRaw = (item['MUSICRID'] ?? '').toString();
      final rid = ridRaw.split('_').last;
      if (rid.isEmpty) continue;
      final durSec = int.tryParse('${item['DURATION'] ?? ''}') ?? 0;
      final pic = (item['web_albumpic_short'] ?? '').toString();
      out.add(
        KuwoSong(
          rid: rid,
          name: (item['NAME'] ?? '').toString().trim(),
          artists: (item['ARTIST'] ?? '')
              .toString()
              .replaceAll('&', ' / ')
              .trim(),
          album: (item['ALBUM'] ?? '').toString().trim(),
          durationMs: durSec * 1000,
          coverUrl: pic.isEmpty
              ? null
              // web_albumpic_short 形如 "120/xx/xx/xxx.jpg"，开头那段是尺寸，
              // 换成 500 取大图（否则 120 缩略图放大很糊）。
              : 'https://img1.kuwo.cn/star/albumcover/'
                    '${pic.replaceFirst(RegExp(r'^\d+/'), '500/')}',
          isVip: false,
        ),
      );
    }
    return out;
  }

  List<KuwoSong> _parseList(dynamic list) {
    if (list is! List) return const [];
    final out = <KuwoSong>[];
    for (final item in list) {
      if (item is Map) {
        final s = KuwoSong.fromJson(item.cast<String, dynamic>());
        if (s != null) out.add(s);
      }
    }
    return out;
  }
}
