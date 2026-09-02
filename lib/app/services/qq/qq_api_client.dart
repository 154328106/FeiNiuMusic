import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'qq_auth.dart';
import 'qq_models.dart';

class QQApiException implements Exception {
  QQApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      'QQApiException($message${code == null ? '' : ', code=$code'})';
}

/// QQ 音乐接口。
///
/// 和网易云最大的不同：**这边根本没有加密**。网易云要 AES-128-CBC 两轮加
/// RSA 裸幂运算，QQ 就是往 `musicu.fcg` 发一段普通 JSON，`comm` 块里写上
/// 客户端版本就行。签名（`g_tk`）只有账号级的写操作才要，浏览、搜索、
/// 取播放地址都不需要登录。
///
/// 参考 Beans-Music 的 QQMusicAPI.swift。
class QQApiClient {
  QQApiClient._();

  static final QQApiClient instance = QQApiClient._();

  static const String _musicu = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

  /// 取播放地址要带一个设备 guid。QQ 只校验格式（纯数字），不校验来源，
  /// 所以进程内随机生成一个用到底即可。
  static final String _guid = (Random().nextInt(900000000) + 100000000)
      .toString();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) '
            'Gecko/20100101 Firefox/80.0',
        'Referer': 'https://y.qq.com/',
      },
    ),
  );

  /// 往 musicu.fcg 发一段 JSON。
  ///
  /// 走 GET + `data=<json>`：这个接口 GET/POST 都收，GET 少一次预检，
  /// 且和 Beans 那边取 vkey 的方式一致。
  Future<Map<String, dynamic>> _musicuCall(Map<String, Object?> payload) async {
    final Response<String> response;
    try {
      response = await _dio.get<String>(
        _musicu,
        queryParameters: {'format': 'json', 'data': jsonEncode(payload)},
        // 带上登录态：没登录时 QQAuth 给的是一份游客 Cookie。
        options: Options(headers: {'Cookie': QQAuth.instance.cookieHeader}),
      );
    } on DioException catch (e) {
      throw QQApiException('网络请求失败：${e.message ?? e.type.name}');
    }
    if (response.statusCode != 200) {
      throw QQApiException(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.data ?? '{}');
    if (decoded is! Map<String, dynamic>) {
      throw QQApiException('响应格式异常');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _getJson(String url, {String? referer}) async {
    final Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: Options(
          headers: {
            'Cookie': QQAuth.instance.cookieHeader,
            // `?:` 是空安全的 map 元素：referer 为 null 时这一项直接不出现。
            'Referer': ?referer,
          },
        ),
      );
    } on DioException catch (e) {
      throw QQApiException('网络请求失败：${e.message ?? e.type.name}');
    }
    if (response.statusCode != 200) {
      throw QQApiException(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    // 部分接口会用 jsonpCallback(...) 包一层，这里剥掉。
    var body = (response.data ?? '').trim();
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start > 0 && end > start) body = body.substring(start, end + 1);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw QQApiException('响应格式异常');
    return decoded;
  }

  /// 按点分路径取值，中途缺一层就返回 null。
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

  // ---------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------

  /// 搜索歌曲。
  ///
  /// 主通道是 `search_for_qq_cp` 这条纯 GET 的老接口 —— 和榜单、歌单详情
  /// 一样，它比 musicu 上对应的模块稳得多。musicu 那条留作兜底：实测它
  /// 偶尔返回空，表现就是「搜几次才搜得到」。
  Future<List<QQSong>> searchSongs(String keyword, {int limit = 30}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    try {
      final songs = await _searchViaClient(query, limit: limit);
      if (songs.isNotEmpty) return songs;
      debugPrint('[QQ] 老接口搜索为空，换 musicu 再试');
    } on QQApiException catch (e) {
      debugPrint('[QQ] 老接口搜索失败：${e.message}，换 musicu 再试');
    }
    return _searchViaMusicu(query, limit: limit);
  }

  Future<List<QQSong>> _searchViaClient(
    String keyword, {
    required int limit,
  }) async {
    final json = await _getJson(
      'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp'
      '?format=json&w=${Uri.encodeQueryComponent(keyword)}'
      '&n=$limit&p=1&t=0',
      referer: 'https://y.qq.com/portal/search.html',
    );
    final list = _at(json, ['data', 'song', 'list']) as List?;
    return _toSongs(list);
  }

  Future<List<QQSong>> _searchViaMusicu(
    String keyword, {
    required int limit,
  }) async {
    final json = await _musicuCall({
      'comm': {'ct': 19, 'cv': 1859, 'uin': '0', 'format': 'json'},
      'req_1': {
        'module': 'music.search.SearchCgiService',
        'method': 'DoSearchForQQMusicDesktop',
        'param': {
          'query': keyword,
          'num_per_page': limit,
          'page_num': 1,
          'search_type': 0,
          'grp': 1,
        },
      },
    });
    final list = _at(json, ['req_1', 'data', 'body', 'song', 'list']) as List?;
    return _toSongs(list);
  }

  // ---------------------------------------------------------------------
  // 歌单
  // ---------------------------------------------------------------------

  /// 推荐歌单。不需要登录。
  Future<List<QQPlaylist>> recommendPlaylists({int limit = 12}) async {
    final json = await _musicuCall({
      'comm': {'ct': 24, 'cv': 0},
      'req_1': {
        'module': 'music.srfDissInfo.RecommendPlaylist',
        'method': 'GetRecommendPlaylist',
        'param': {'uin': 0, 'lastDissid': 0, 'songtype': 1, 'scene': 0},
      },
    });
    final list =
        _at(json, ['req_1', 'data', 'v_playlist']) as List? ?? const [];
    final result = <QQPlaylist>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final id = (item['tid'] as int?) ?? (item['id'] as int?);
      if (id == null) continue;
      result.add(
        QQPlaylist(
          id: id,
          name: item['title'] as String? ?? '',
          coverUrl: _normalizeImage(item['cover'] ?? item['pic_url']),
          trackCount: (item['songnum'] as int?) ?? 0,
        ),
      );
      if (result.length >= limit) break;
    }
    return result;
  }

  /// 歌单内的歌。
  ///
  /// 走 `fcg_ucc_getcdinfo_byids_cp` 这条老接口：纯 GET、免登录、字段稳定。
  /// musicu 上那个 GetPlaylistDetail 试过，返回是空的。
  Future<List<QQSong>> playlistSongs(int tid) async {
    final json = await _getJson(
      'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg'
      '?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=$tid'
      '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8'
      '&notice=0&platform=yqq.json&needNewCode=0',
      referer: 'https://y.qq.com/n/yqq/playlist',
    );
    final cdlist =
        (json['cdlist'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const [];
    if (cdlist.isEmpty) return const [];
    return _toSongs(cdlist.first['songlist'] as List?);
  }

  /// 排行榜歌曲。topid：26 热歌榜、27 新歌榜、62 飙升榜。
  ///
  /// 也是纯 GET 的老接口，不需要登录，字段比 musicu 那套稳。
  Future<List<QQSong>> topListSongs(int topid, {int limit = 30}) async {
    final json = await _getJson(
      'https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg'
      '?format=json&page=detail&type=top&topid=$topid'
      '&song_begin=0&song_num=$limit',
    );
    final list = json['songlist'] as List?;
    if (list == null) return const [];
    // 这个接口把歌塞在 data 里再包一层。
    return _toSongs([
      for (final item in list.whereType<Map<String, dynamic>>())
        (item['data'] as Map<String, dynamic>?) ?? item,
    ]);
  }

  /// 首页推荐：热歌 / 新歌 / 飙升三榜混合去重。
  ///
  /// QQ 的「每日推荐」要登录，这里用三个公开榜拼一份 —— 内容每天会变，
  /// 量也够，而且一个账号都不用。
  Future<List<QQSong>> recommendSongs({int limit = 50}) async {
    final per = ((limit + 2) ~/ 3).clamp(8, 100);
    final seen = <String>{};
    final songs = <QQSong>[];
    for (final topid in const [26, 27, 62]) {
      try {
        for (final song in await topListSongs(topid, limit: per)) {
          if (seen.add(song.mid)) songs.add(song);
        }
      } on QQApiException catch (e) {
        debugPrint('[QQ] 榜单 $topid 读取失败：${e.message}');
      }
    }
    // 按当天日期做种子打乱：每天换一批，但**同一天内顺序固定**。
    //
    // 之前用无参 shuffle()，每次调用顺序都不一样 —— 而点歌播放时会再拉一次
    // 完整列表当队列，于是「屏幕上第 3 首」和「队列里第 3 首」根本不是同一
    // 首歌，表现就是点谁都跳到别的歌。
    final day = DateTime.now();
    final seed = day.year * 10000 + day.month * 100 + day.day;
    songs.shuffle(Random(seed));
    return songs.length <= limit ? songs : songs.sublist(0, limit);
  }

  // ---------------------------------------------------------------------
  // 播放地址 / 歌词
  // ---------------------------------------------------------------------

  /// 取播放地址。
  ///
  /// QQ 的文件名要靠 `前缀 + songmid + media_mid + 扩展名` 拼出来，一次可以
  /// 提交多个候选，服务端挑得到哪个给哪个 —— 所以这里把几种历史格式都塞
  /// 进去，别为「拼错一种就没地址」再跑一轮。
  Future<String?> songUrl(String mid, {String? mediaMid}) async {
    // 登录了先试 320k，不行再退 128k；没登录直接 128k —— 高音质要会员，
    // 没登录连试都是白跑一轮。
    final auth = QQAuth.instance;
    final prefixes = auth.isLoggedIn.value
        ? const ['M800', 'M500']
        : const ['M500'];
    for (final prefix in prefixes) {
      final url = await _songUrlWith(prefix, mid, mediaMid);
      if (url != null) return url;
    }
    debugPrint('[QQ] $mid 无可播地址（多半是会员曲）');
    return null;
  }

  Future<String?> _songUrlWith(
    String prefix,
    String mid,
    String? mediaMid,
  ) async {
    final auth = QQAuth.instance;
    final preferred = (mediaMid != null && mediaMid.isNotEmpty)
        ? mediaMid
        : mid;
    final filenames = <String>{
      '$prefix$mid$preferred.mp3',
      '$prefix$preferred.mp3',
      '$prefix$mid$mid.mp3',
      '$prefix$mid.mp3',
    }.toList();

    final loginKey = auth.authst;
    final json = await _musicuCall({
      'comm': {
        'uin': int.tryParse(auth.uin) ?? 0,
        'format': 'json',
        // 登录态下 ct 要用 19，否则服务端按游客处理，会员曲照样不给。
        'ct': loginKey.isEmpty ? 24 : 19,
        'cv': 0,
        if (loginKey.isNotEmpty) 'authst': loginKey,
      },
      'req': {
        'module': 'CDN.SrfCdnDispatchServer',
        'method': 'GetCdnDispatch',
        'param': {'guid': _guid, 'calltype': 0, 'userip': ''},
      },
      'req_0': {
        'module': 'vkey.GetVkeyServer',
        'method': 'CgiGetVkey',
        'param': {
          'filename': filenames,
          'guid': _guid,
          'songmid': List.filled(filenames.length, mid),
          'songtype': List.filled(filenames.length, 0),
          'uin': auth.uin,
          'loginflag': 1,
          'platform': '20',
        },
      },
    });

    final data = _at(json, ['req_0', 'data']);
    if (data is! Map) return null;
    final infos = (data['midurlinfo'] as List?) ?? const [];
    String? purl;
    for (final info in infos.whereType<Map>()) {
      final value = info['purl'] as String?;
      if (value != null && value.isNotEmpty) {
        purl = value;
        break;
      }
    }
    if (purl == null) return null;
    if (purl.startsWith('http')) return purl;
    final sips = (data['sip'] as List?)?.whereType<String>().toList();
    final base = (sips == null || sips.isEmpty)
        ? 'https://isure.stream.qqmusic.qq.com/'
        : sips.first;
    return '$base$purl';
  }

  /// 歌词。`nobase64=1` 直接给明文 LRC，省一次解码。
  Future<String?> lyric(String mid) async {
    // 这个接口对 Referer 敏感，必须是播放页那个地址，否则返回 retcode 非 0。
    final json = await _getJson(
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg'
      '?songmid=${Uri.encodeQueryComponent(mid)}'
      '&format=json&nobase64=1&g_tk=5381',
      referer: 'https://y.qq.com/portal/player.html',
    );
    final lyric = json['lyric'] as String?;
    if (lyric == null || lyric.isEmpty) {
      debugPrint('[QQ] $mid 没有歌词：retcode=${json['retcode']}');
      return null;
    }
    return lyric;
  }

  // ---------------------------------------------------------------------

  static List<QQSong> _toSongs(List? list) {
    if (list == null) return const [];
    final songs = <QQSong>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      // 歌单接口有时把歌塞在 songInfo 里再包一层。
      final raw = (item['songInfo'] as Map<String, dynamic>?) ?? item;
      final song = QQSong.fromJson(raw);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  /// QQ 返回的图片地址有裸路径、`//` 开头等好几种写法，统一补成完整 https。
  static String? _normalizeImage(Object? value) {
    if (value is! String || value.isEmpty) return null;
    if (value.startsWith('https://')) return value;
    if (value.startsWith('http://')) {
      return 'https://${value.substring(7)}';
    }
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return 'https://y.gtimg.cn$value';
    return 'https://y.gtimg.cn/${value.replaceAll(RegExp(r'^/+'), '')}';
  }
}
