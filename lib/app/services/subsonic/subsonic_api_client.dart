import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'subsonic_response.dart';
import 'subsonic_server.dart';

class SubsonicApiException implements Exception {
  SubsonicApiException(this.message, {this.code});

  final String message;

  /// Subsonic 的 error code。40 = 凭据错，41 = 不支持 token 认证，70 = 找不到。
  final int? code;

  @override
  String toString() =>
      'SubsonicApiException($message${code == null ? '' : ', code=$code'})';
}

/// Subsonic 协议客户端。
///
/// 一套实现同时覆盖 Navidrome 和 NAS 上 4000 端口那个服务 —— 它们说的是同一个
/// 协议，只是 JSON 形状不同，差异在 [normalizeSubsonic] 里抹平。
///
/// 与网易云那套的关键差别：**Subsonic 的播放地址是稳定直链**
/// （`/rest/stream.view?id=...`，带鉴权参数），不像网易云是带签名的临时地址，
/// 所以可以直接存进 `SongEntity.uri` 反复使用，不必每次播放前重新解析。
class SubsonicApiClient {
  SubsonicApiClient._();

  static final SubsonicApiClient instance = SubsonicApiClient._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  SubsonicServerConfig get _config => SubsonicServerStore.instance.config.value;

  bool get isConfigured => _config.isConfigured;

  /// 拼一个带鉴权参数的完整 URL。播放地址、封面地址都走这里。
  String buildUrl(String endpoint, [Map<String, String> extra = const {}]) {
    final config = _config;
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final query = {...subsonicAuthQuery(config), ...extra};
    final qs = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$base/rest/$endpoint?$qs';
  }

  /// 歌曲播放直链。稳定，可持久化。
  String streamUrl(String songId) =>
      buildUrl('stream.view', {'id': songId});

  /// 封面地址。[size] 传 0 表示原图。
  String coverUrl(String coverArtId, {int size = 512}) => buildUrl(
    'getCoverArt.view',
    {'id': coverArtId, if (size > 0) 'size': '$size'},
  );

  /// 发一次请求，返回**已拍平**的 `subsonic-response` 内容。
  ///
  /// 撞上 code 41（服务端不支持 token 认证）时自动降级成密码模式并重试一次，
  /// 顺手把降级结果存下来，之后不用每次都先失败一轮。
  Future<Map<String, Object?>> _request(
    String endpoint, [
    Map<String, String> extra = const {},
  ]) async {
    try {
      return await _send(endpoint, extra);
    } on SubsonicApiException catch (e) {
      if (e.code != 41 || _config.authMode != SubsonicAuthMode.token) rethrow;
      debugPrint('[Subsonic] 服务端不支持 token 认证，降级为密码模式');
      await SubsonicServerStore.instance.save(
        _config.copyWith(authMode: SubsonicAuthMode.password),
      );
      return _send(endpoint, extra);
    }
  }

  Future<Map<String, Object?>> _send(
    String endpoint,
    Map<String, String> extra,
  ) async {
    if (!isConfigured) {
      throw SubsonicApiException('未配置服务器');
    }
    final url = buildUrl(endpoint, extra);

    final Response<String> response;
    try {
      response = await _dio.get<String>(url);
    } on DioException catch (e) {
      throw SubsonicApiException('网络请求失败：${e.message ?? e.type.name}');
    }

    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    if (status != 200) {
      throw SubsonicApiException('HTTP $status', code: status);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw SubsonicApiException(
        '响应不是合法 JSON：${body.length > 120 ? '${body.substring(0, 120)}…' : body}',
      );
    }
    if (decoded is! Map) throw SubsonicApiException('响应格式异常');

    final envelope = decoded['subsonic-response'];
    if (envelope == null) throw SubsonicApiException('响应缺少 subsonic-response');

    final flat = normalizeSubsonic(envelope);
    if (flat is! Map<String, Object?>) {
      throw SubsonicApiException('响应结构无法解析');
    }

    if (subsonicStr(flat['status']) == 'failed') {
      final err = flat['error'];
      final errMap = err is Map<String, Object?> ? err : const <String, Object?>{};
      throw SubsonicApiException(
        subsonicStr(errMap['message'], fallback: '未知错误'),
        code: subsonicInt(errMap['code'], fallback: -1),
      );
    }
    return flat;
  }

  // ---------------------------------------------------------------------
  // 接口
  // ---------------------------------------------------------------------

  /// 连接测试。成功返回服务端版本号。
  Future<String> ping() async {
    final json = await _request('ping.view');
    return subsonicStr(json['version'], fallback: 'unknown');
  }

  /// 搜索歌曲。`search3` 是 ID3 标签检索，比 `search2` 结果干净。
  Future<List<Map<String, Object?>>> searchSongs(
    String keyword, {
    int count = 50,
    int offset = 0,
  }) async {
    final json = await _request('search3.view', {
      'query': keyword,
      'songCount': '$count',
      'songOffset': '$offset',
      'artistCount': '0',
      'albumCount': '0',
    });
    final result = json['searchResult3'];
    if (result is! Map) return const [];
    return subsonicList(result['song']);
  }

  /// 专辑列表。[type] 可用 `newest` / `recent` / `frequent` / `random` /
  /// `alphabeticalByName` 等。
  Future<List<Map<String, Object?>>> albumList({
    String type = 'newest',
    int size = 50,
    int offset = 0,
  }) async {
    final json = await _request('getAlbumList2.view', {
      'type': type,
      'size': '$size',
      'offset': '$offset',
    });
    final result = json['albumList2'];
    if (result is! Map) return const [];
    return subsonicList(result['album']);
  }

  /// 专辑内的歌曲。
  Future<List<Map<String, Object?>>> albumSongs(String albumId) async {
    final json = await _request('getAlbum.view', {'id': albumId});
    final album = json['album'];
    if (album is! Map) return const [];
    return subsonicList(album['song']);
  }

  Future<List<Map<String, Object?>>> playlists() async {
    final json = await _request('getPlaylists.view');
    final result = json['playlists'];
    if (result is! Map) return const [];
    return subsonicList(result['playlist']);
  }

  Future<List<Map<String, Object?>>> playlistSongs(String playlistId) async {
    final json = await _request('getPlaylist.view', {'id': playlistId});
    final playlist = json['playlist'];
    if (playlist is! Map) return const [];
    return subsonicList(playlist['entry']);
  }

  /// 收藏（星标）的歌曲。
  Future<List<Map<String, Object?>>> starredSongs() async {
    final json = await _request('getStarred2.view');
    final result = json['starred2'];
    if (result is! Map) return const [];
    return subsonicList(result['song']);
  }

  Future<List<Map<String, Object?>>> randomSongs({int count = 50}) async {
    final json = await _request('getRandomSongs.view', {'size': '$count'});
    final result = json['randomSongs'];
    if (result is! Map) return const [];
    return subsonicList(result['song']);
  }

  Future<void> star(String songId, {required bool starred}) async {
    await _request(starred ? 'star.view' : 'unstar.view', {'id': songId});
  }

  /// 歌词。先试 `getLyricsBySongId`（OpenSubsonic 扩展，能拿到带时间轴的
  /// LRC），服务端不支持再退回按「歌手 + 标题」查的 `getLyrics`（多为纯文本）。
  Future<String?> lyrics({
    required String songId,
    String? artist,
    String? title,
  }) async {
    try {
      final json = await _request('getLyricsBySongId.view', {'id': songId});
      final container = json['lyricsList'];
      if (container is Map) {
        final entries = subsonicList(container['structuredLyrics']);
        for (final entry in entries) {
          final lines = subsonicList(entry['line']);
          if (lines.isEmpty) continue;
          // 有 start 就还原成 LRC 时间轴，没有就只留文本。
          final buffer = StringBuffer();
          for (final line in lines) {
            final text = subsonicStr(line['value']);
            final start = line['start'];
            if (start == null) {
              buffer.writeln(text);
              continue;
            }
            final ms = subsonicInt(start);
            final m = (ms ~/ 60000).toString().padLeft(2, '0');
            final s = ((ms % 60000) / 1000).toStringAsFixed(2).padLeft(5, '0');
            buffer.writeln('[$m:$s]$text');
          }
          final out = buffer.toString().trim();
          if (out.isNotEmpty) return out;
        }
      }
    } on SubsonicApiException catch (e) {
      debugPrint('[Subsonic] getLyricsBySongId 不可用：${e.message}');
    }

    if ((artist ?? '').isEmpty && (title ?? '').isEmpty) return null;
    try {
      final json = await _request('getLyrics.view', {
        if ((artist ?? '').isNotEmpty) 'artist': artist!,
        if ((title ?? '').isNotEmpty) 'title': title!,
      });
      final lyrics = json['lyrics'];
      if (lyrics is Map) {
        final text = subsonicStr(lyrics['value'] ?? lyrics['_text']);
        return text.trim().isEmpty ? null : text;
      }
      if (lyrics is String && lyrics.trim().isNotEmpty) return lyrics;
    } on SubsonicApiException catch (e) {
      debugPrint('[Subsonic] getLyrics 失败：${e.message}');
    }
    return null;
  }
}
