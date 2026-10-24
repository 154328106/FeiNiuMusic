import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'migu_models.dart';

class MiguApiException implements Exception {
  MiguApiException(this.message);
  final String message;
  @override
  String toString() => 'MiguApiException: $message';
}

/// 咪咕音乐 API 客户端（搜索 + 歌词）。
///
/// 搜索走 `pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do`：**免签名**，
/// 只要带 `channel: 0146921` 头 + okhttp UA，就回干净 JSON（含 copyrightId /
/// contentId / 多档图片封面 / 音质）。这是咪咕比酷我强的地方 —— 搜索结果自带
/// 真封面，不像酷我榜单一片灰。
///
/// 播放地址不在这里：咪咕自家直链要登录（见 [MiguPlaybackService]），免登录
/// 时走聚合/LX 的 mg 后端。
class MiguApiClient {
  MiguApiClient._();
  static final MiguApiClient instance = MiguApiClient._();

  static const String _channel = '0146921';
  static const String _ua = 'okhttp/3.12.1';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      // 自己 decode：search_all.do 偶发以 text/plain 回 JSON。
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  Map<String, String> get _headers => {
    'channel': _channel,
    'User-Agent': _ua,
  };

  dynamic _decode(dynamic data) {
    if (data is Map || data is List) return data;
    if (data is String && data.isNotEmpty) {
      try {
        return jsonDecode(data);
      } catch (_) {}
    }
    return null;
  }

  /// 关键字搜歌。
  Future<List<MiguSong>> search(String keyword, {int limit = 30}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    try {
      final res = await _dio.get<dynamic>(
        'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do',
        queryParameters: {
          'ua': 'Android_migu',
          'version': '5.0.1',
          'pageNo': 1,
          'pageSize': limit,
          'searchSwitch': '{"song":1}',
          'text': kw,
        },
        options: Options(headers: _headers),
      );
      final json = _decode(res.data);
      if (json is! Map || json['code'] != '000000') {
        debugPrint('[Migu] 搜索 code=${json is Map ? json['code'] : '?'}');
        return const [];
      }
      final result = (json['songResultData'] is Map)
          ? (json['songResultData'] as Map)['result']
          : null;
      return _parseList(result);
    } catch (e) {
      debugPrint('[Migu] 搜索异常：$e');
      return const [];
    }
  }

  /// 榜单：`querycontentbyId.do?columnId=<id>`，返回 `columnInfo.contents[]`，
  /// 每项 `objectInfo` 是一首歌（字段名和搜索不同，用 fromChartJson 解析）。
  Future<List<MiguSong>> chart(String columnId, {int limit = 50}) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do',
        queryParameters: {
          'columnId': columnId,
          'needSimple': '00',
          'pageSize': limit,
        },
        options: Options(headers: _headers),
      );
      final json = _decode(res.data);
      if (json is! Map || json['code'] != '000000') return const [];
      final contents = (json['columnInfo'] is Map)
          ? (json['columnInfo'] as Map)['contents']
          : null;
      if (contents is! List) return const [];
      final out = <MiguSong>[];
      for (final c in contents) {
        final oi = (c is Map) ? c['objectInfo'] : null;
        if (oi is Map) {
          final s = MiguSong.fromChartJson(oi.cast<String, dynamic>());
          if (s != null) out.add(s);
        }
      }
      return out;
    } catch (e) {
      debugPrint('[Migu] 榜单异常：$e');
      return const [];
    }
  }

  /// 歌词：直接拉搜索结果里带的 .lrc 直链。
  Future<String?> lyric(String lyricUrl) async {
    final u = lyricUrl.trim();
    if (!u.startsWith('http')) return null;
    try {
      final res = await _dio.get<dynamic>(
        u,
        options: Options(headers: {'User-Agent': _ua}),
      );
      final text = res.data is String ? res.data as String : '${res.data}';
      final lrc = text.trim();
      // 简单校验：像 LRC（含时间标签）才认，避免把一页 HTML/错误当歌词。
      if (lrc.isEmpty || !lrc.contains(RegExp(r'\[\d{1,2}:\d{2}'))) return null;
      return lrc;
    } catch (e) {
      debugPrint('[Migu] 歌词异常：$e');
      return null;
    }
  }

  List<MiguSong> _parseList(dynamic list) {
    if (list is! List) return const [];
    final out = <MiguSong>[];
    for (final item in list) {
      if (item is Map) {
        final s = MiguSong.fromJson(item.cast<String, dynamic>());
        if (s != null) out.add(s);
      }
    }
    return out;
  }
}
