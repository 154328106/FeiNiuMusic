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
/// 走酷我 www 接口（`www.kuwo.cn/api/www/...`）。它有一道很轻的反爬：请求头
/// `csrf` 必须等于 Cookie 里的 `kw_token`，值随便填、两者一致即可。返回干净的
/// JSON（含完整封面 http 地址），比 search.kuwo.cn 的 r.s 好解析。
class KuwoApiClient {
  KuwoApiClient._();
  static final KuwoApiClient instance = KuwoApiClient._();

  // 任意字符串，只要 header csrf 和 cookie kw_token 一致即可。
  static final String _token = () {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  }();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  );

  Map<String, String> get _headers => {
    'csrf': _token,
    'Cookie': 'kw_token=$_token',
    'Referer': 'https://www.kuwo.cn/',
    'Host': 'www.kuwo.cn',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };

  String _reqId() {
    final r = Random();
    return List.generate(
      32,
      (_) => '0123456789abcdef'[r.nextInt(16)],
    ).join();
  }

  Future<Map<String, dynamic>> _www(
    String path,
    Map<String, dynamic> params,
  ) async {
    final res = await _dio.get<dynamic>(
      'https://www.kuwo.cn$path',
      queryParameters: {
        ...params,
        'httpsStatus': 1,
        'reqId': _reqId(),
      },
      options: Options(headers: _headers),
    );
    final data = res.data;
    if (data is Map && data['code'] == 200 && data['data'] is Map) {
      return (data['data'] as Map).cast<String, dynamic>();
    }
    throw KuwoApiException('接口异常：code=${data is Map ? data['code'] : '?'}');
  }

  /// 关键字搜歌。
  Future<List<KuwoSong>> search(String keyword, {int limit = 30}) async {
    if (keyword.trim().isEmpty) return const [];
    try {
      final data = await _www('/api/www/search/searchMusicBykeyWord', {
        'key': keyword.trim(),
        'pn': 1,
        'rn': limit,
      });
      return _parseList(data['list']);
    } on KuwoApiException {
      rethrow;
    } catch (e) {
      debugPrint('[Kuwo] 搜索失败：$e');
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
      return _parseList(data['musicList']);
    } catch (e) {
      debugPrint('[Kuwo] 榜单失败：$e');
      return const [];
    }
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
