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

  Map<String, String> get _wwwHeaders => {
    'csrf': _token,
    'Cookie': 'kw_token=$_token',
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
    final res = await _dio.get<dynamic>(
      'https://www.kuwo.cn$path',
      queryParameters: {...params, 'httpsStatus': 1, 'reqId': _reqId()},
      options: Options(headers: _wwwHeaders),
    );
    final json = _decode(res.data);
    if (json is Map && json['code'] == 200 && json['data'] is Map) {
      return (json['data'] as Map).cast<String, dynamic>();
    }
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
              : 'https://img1.kuwo.cn/star/albumcover/$pic',
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
