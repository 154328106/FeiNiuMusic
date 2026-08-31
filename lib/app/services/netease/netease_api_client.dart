import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'netease_crypto.dart';
import 'netease_models.dart';

/// 走哪套加密。见 [NetEaseCrypto]。
enum _Scheme { weapi, eapi }

class NetEaseApiException implements Exception {
  NetEaseApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      'NetEaseApiException($message${code == null ? '' : ', code=$code'})';
}

/// 网易云音乐接口客户端。
///
/// 移植自 Beans-Music 的 Swift 实现。要点：
///
/// - **自己管 Cookie，不用 CookieJar**：网易云的登录态是 `MUSIC_U` + `__csrf`
///   两个 Cookie，同时请求头里还要伪装一整套 PC 客户端标识（`os`/`appver`/
///   `deviceId`…）。这些是随请求构造的，不是服务端下发的，交给自动 Cookie
///   管理反而会打架。
/// - **设备标识进程内固定**：`deviceId`/`nuid` 每次启动随机生成后保持不变。
///   同一次会话里来回变会被判定为异常设备。
/// - **eapi 优先、weapi 降级**：扫码登录两条路都试，网易云对 web 端接口的
///   风控比客户端接口紧。
class NetEaseApiClient {
  NetEaseApiClient._() {
    _nuid = _randomHex(32);
    _deviceId = _randomHex(26);
    _wnMcid =
        '${_randomLowercase(6)}.${DateTime.now().millisecondsSinceEpoch}.01.0';
  }

  static final NetEaseApiClient instance = NetEaseApiClient._();

  static const String _webDomain = 'https://music.163.com';
  static const String _apiDomain = 'https://interface.music.163.com';
  static const String _prefsCookieKey = 'netease.cookies';

  // 模拟 PC 客户端环境（与 NeteaseCloudMusicApi 保持一致）
  static const String _os = 'pc';
  static const String _appver = '3.1.17.204416';
  static const String _osver =
      'Microsoft-Windows-10-Professional-build-19045-64bit';
  static const String _channel = 'netease';
  static const String _webUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0';
  static const String _clientUserAgent =
      'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)';

  static final Random _random = Random();

  late final String _nuid;
  late final String _deviceId;
  late final String _wnMcid;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      // 自己解析 JSON：网易云偶尔返回 text/plain，让 dio 自动解会抛。
      responseType: ResponseType.plain,
      // 4xx/5xx 也拿回来，好把服务端的错误信息带进异常里。
      validateStatus: (_) => true,
    ),
  );

  Map<String, String> _cookies = {};
  bool _loaded = false;

  // ---------------------------------------------------------------------
  // 登录态
  // ---------------------------------------------------------------------

  String get _csrfToken => _cookies['__csrf'] ?? '';
  String get _musicU => _cookies['MUSIC_U'] ?? '';

  /// 是否已登录（有 MUSIC_U 即视为已登录）。
  bool get isLoggedIn => _musicU.isNotEmpty;

  /// 从磁盘恢复登录 Cookie。App 启动时调用一次。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsCookieKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _cookies = decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {
      // 存档损坏就当没登录，不要卡住启动。
    }
  }

  /// 续一次登录态。
  ///
  /// 网易云的 MUSIC_U 会过期，过期后表现很隐蔽：收藏、播放记录忽然变空，
  /// 但界面上还是「已登录」。启动时打一发，服务端会把新的 Cookie 从
  /// Set-Cookie 回给我们（`_request` 里已经在吸收了）。失败不用管 ——
  /// 真过期了后面的接口会报 301，那边有既有的处理。
  Future<void> refreshLogin() async {
    if (!isLoggedIn) return;
    try {
      await _request('/api/login/token/refresh', const {}, _Scheme.weapi);
    } catch (_) {
      // 续期失败不影响本次使用。
    }
  }

  Future<void> logout() async {
    _cookies = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsCookieKey);
    } catch (_) {}
  }

  Future<void> _persistCookies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsCookieKey, jsonEncode(_cookies));
    } catch (_) {}
  }

  /// 合并 WebView 里抓到的 Cookie（网页登录用）。
  Future<void> importWebCookies(Map<String, String> cookies) async {
    var changed = false;
    cookies.forEach((k, v) {
      if (v.isNotEmpty && _cookies[k] != v) {
        _cookies[k] = v;
        changed = true;
      }
    });
    if (changed) await _persistCookies();
  }

  void _storeSetCookies(Headers headers) {
    final raw = headers.map['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    var changed = false;
    for (final line in raw) {
      // Set-Cookie 的第一段就是 name=value，后面是 Path/Expires 等属性。
      final pair = line.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (value.isEmpty) continue;
      if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    if (changed) unawaited(_persistCookies());
  }

  // ---------------------------------------------------------------------
  // 请求
  // ---------------------------------------------------------------------

  /// [uri] 是 api 路径（`/api/...`）。weapi 走 `music.163.com/weapi/...`，
  /// eapi 走 `interface.music.163.com/eapi/...`，都是把 `/api` 前缀替换掉。
  Future<Map<String, dynamic>> _request(
    String uri,
    Map<String, dynamic> payload,
    _Scheme scheme,
  ) async {
    await load();

    final String url;
    final String form;
    final Map<String, String> headers;

    if (scheme == _Scheme.weapi) {
      url = '$_webDomain/weapi${uri.substring(4)}';
      final data = {...payload, 'csrf_token': _csrfToken};
      final enc = NetEaseCrypto.weapi(data);
      form =
          'params=${_formEncode(enc['params']!)}'
          '&encSecKey=${_formEncode(enc['encSecKey']!)}';
      headers = {
        'Cookie': _weapiCookieHeader(),
        'User-Agent': _webUserAgent,
        'Referer': _webDomain,
      };
    } else {
      url = '$_apiDomain/eapi${uri.substring(4)}';
      final eapiHeader = _eapiHeader();
      // e_r=false 表示响应不加密；header 字段是客户端标识，参与摘要计算。
      final data = {...payload, 'e_r': false, 'header': eapiHeader};
      final enc = NetEaseCrypto.eapi(data, uri);
      form = 'params=${_formEncode(enc['params']!)}';
      headers = {
        'Cookie': _eapiCookieHeader(eapiHeader),
        'User-Agent': _clientUserAgent,
      };
    }

    final Response<String> response;
    try {
      response = await _dio.post<String>(
        url,
        data: form,
        options: Options(
          headers: {
            ...headers,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );
    } on DioException catch (e) {
      throw NetEaseApiException('网络请求失败：${e.message ?? e.type.name}');
    }

    _storeSetCookies(response.headers);

    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    if (status != 200) {
      throw NetEaseApiException('HTTP $status：${_snippet(body)}', code: status);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw NetEaseApiException('响应不是合法 JSON：${_snippet(body)}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw NetEaseApiException('响应格式异常：${_snippet(body)}');
    }
    return decoded;
  }

  static String _snippet(String body) =>
      body.length <= 120 ? body : '${body.substring(0, 120)}…';

  /// 按 RFC 3986 unreserved 字符集做百分号编码。
  ///
  /// 不能用 `Uri.encodeComponent`：它会放过几个子分隔符，而 base64 的 `+/=`
  /// 必须编码。保持与 Swift 端一致的严格集合最省心。
  static String _formEncode(String value) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      if (unreserved.contains(char)) {
        buffer.write(char);
      } else {
        buffer.write(
          '%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}',
        );
      }
    }
    return buffer.toString();
  }

  String _weapiCookieHeader() {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final parts = <String>[
      '__remember_me=true',
      'ntes_kaola_ad=1',
      '_ntes_nuid=$_nuid',
      '_ntes_nnid=$_nuid,$ts',
      'WNMCID=$_wnMcid',
      'WEVNSM=1.0.0',
      'osver=$_osver',
      'deviceId=$_deviceId',
      'os=$_os',
      'channel=$_channel',
      'appver=$_appver',
      'NMTID=${_randomHex(16)}',
      if (_musicU.isNotEmpty) 'MUSIC_U=$_musicU',
      if (_csrfToken.isNotEmpty) '__csrf=$_csrfToken',
    ];
    return parts.join('; ');
  }

  Map<String, dynamic> _eapiHeader() {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    return {
      'osver': _osver,
      'deviceId': _deviceId,
      'os': _os,
      'appver': _appver,
      'versioncode': '140',
      'mobilename': '',
      'buildver': ts.substring(0, 10),
      'resolution': '1920x1080',
      '__csrf': _csrfToken,
      'channel': _channel,
      'requestId': '${ts}_${_random.nextInt(1000).toString().padLeft(4, '0')}',
      if (_musicU.isNotEmpty) 'MUSIC_U': _musicU,
    };
  }

  String _eapiCookieHeader(Map<String, dynamic> header) => header.entries
      .map((e) => '${e.key}=${Uri.encodeComponent('${e.value}')}')
      .join('; ');

  static String _randomHex(int length) => List.generate(
    length,
    (_) => '0123456789abcdef'[_random.nextInt(16)],
  ).join();

  static String _randomLowercase(int length) => List.generate(
    length,
    (_) => 'abcdefghijklmnopqrstuvwxyz'[_random.nextInt(26)],
  ).join();

  // ---------------------------------------------------------------------
  // 扫码登录
  // ---------------------------------------------------------------------

  /// 申请二维码 key。eapi 失败时降级到 weapi。
  Future<String> qrKey() async {
    for (final scheme in [_Scheme.eapi, _Scheme.weapi]) {
      try {
        final json = await _request('/api/login/qrcode/unikey', {
          'type': 3,
        }, scheme);
        final key =
            json['unikey'] as String? ??
            (json['data'] as Map?)?['unikey'] as String?;
        if (key != null && key.isNotEmpty) return key;
      } on NetEaseApiException catch (e) {
        debugPrint('[NetEase] qrKey ${scheme.name} 失败：${e.message}');
      }
    }
    throw NetEaseApiException('获取二维码密钥失败');
  }

  /// 二维码内容（用它生成图片给用户扫）。
  String qrLoginUrl(String key) => 'https://music.163.com/login?codekey=$key';

  /// 轮询扫码状态。登录成功时 Cookie 已在 [_storeSetCookies] 里落库。
  Future<NetEaseQrStatus> qrCheck(String key) async {
    for (final scheme in [_Scheme.eapi, _Scheme.weapi]) {
      try {
        final json = await _request('/api/login/qrcode/client/login', {
          'key': key,
          'type': 3,
        }, scheme);
        final code = json['code'];
        if (code is int && code != -1) return NetEaseQrStatus.fromCode(code);
      } on NetEaseApiException catch (e) {
        debugPrint('[NetEase] qrCheck ${scheme.name} 失败：${e.message}');
      }
    }
    return NetEaseQrStatus.unknown;
  }

  Future<NetEaseUser> account() async {
    final json = await _request('/api/w/nuser/account/get', {}, _Scheme.weapi);
    final profile = json['profile'];
    final user = profile is Map<String, dynamic>
        ? NetEaseUser.fromJson(profile)
        : null;
    if (user == null) throw NetEaseApiException('获取账号信息失败');
    return user;
  }

  // ---------------------------------------------------------------------
  // 搜索 / 播放 / 歌词
  // ---------------------------------------------------------------------

  Future<List<NetEaseSong>> searchSongs(
    String keyword, {
    int limit = 30,
    int offset = 0,
  }) async {
    final json = await _request('/api/cloudsearch/pc', {
      's': keyword,
      'type': 1,
      'limit': limit,
      'offset': offset,
      'total': true,
    }, _Scheme.weapi);
    final songs = (json['result'] as Map?)?['songs'] as List? ?? const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(NetEaseSong.fromJson)
        .whereType<NetEaseSong>()
        .toList();
  }

  /// 批量取播放地址。
  ///
  /// [level] 可选 `standard` / `higher` / `exhigh` / `lossless` / `hires`，
  /// 高音质需要会员，非会员会自动降级或只给试听片段。
  Future<Map<int, NetEaseSongUrl>> songUrls(
    List<int> ids, {
    String level = 'standard',
  }) async {
    if (ids.isEmpty) return {};

    // 只走 eapi。曾怀疑过 eapi 带不上登录态（收藏走 weapi 正常、取地址失败），
    // 加过 weapi 兜底；实测 eapi 是好的（48/54 有地址），取不到的那几首在
    // weapi 上同样是 0，纯属下架。兜底已去掉，免得每次多打一轮请求。
    final result = await _songUrlsVia(_Scheme.eapi, ids, level);
    final resolved = result.values.where((e) => e.url != null).length;
    debugPrint('[NetEase] songUrls: $resolved/${ids.length} 有地址');
    return result;
  }

  Future<Map<int, NetEaseSongUrl>> _songUrlsVia(
    _Scheme scheme,
    List<int> ids,
    String level,
  ) async {
    final Map<String, dynamic> json;
    try {
      json = await _request('/api/song/enhance/player/url/v1', {
        'ids': '[${ids.join(',')}]',
        'level': level,
        'encodeType': 'flac',
      }, scheme);
    } on NetEaseApiException catch (e) {
      debugPrint('[NetEase] songUrls ${scheme.name} 失败：${e.message}');
      return {};
    }

    final data = json['data'] as List? ?? const [];
    final result = <int, NetEaseSongUrl>{};
    for (final item in data.whereType<Map<String, dynamic>>()) {
      final id = item['id'];
      if (id is! int) continue;
      final rawUrl = item['url'] as String?;
      result[id] = NetEaseSongUrl(
        id: id,
        url: (rawUrl == null || rawUrl.isEmpty) ? null : rawUrl,
        // 有 freeTrialInfo 就说明只给了试听片段。
        freeTrial: item['freeTrialInfo'] != null,
        bitrate: item['br'] as int?,
        type: item['type'] as String?,
      );
    }
    return result;
  }

  /// 歌词 + 翻译（LRC 原文）。
  Future<({String? lrc, String? translated})> lyric(int id) async {
    final json = await _request('/api/song/lyric', {
      'id': id,
      'lv': -1,
      'kv': -1,
      'tv': -1,
    }, _Scheme.weapi);
    return (
      lrc: (json['lrc'] as Map?)?['lyric'] as String?,
      translated: (json['tlyric'] as Map?)?['lyric'] as String?,
    );
  }

  // ---------------------------------------------------------------------
  // 首页内容
  //
  // 除「推荐歌单 / 新歌」外都需要登录：网易云的收藏、播放记录、每日推荐都是
  // 账号维度的数据，未登录时服务端直接返回失败。
  // ---------------------------------------------------------------------

  /// 用户歌单。第一个通常是「我喜欢的音乐」（红心歌单）。
  Future<List<NetEasePlaylist>> userPlaylists(int uid) async {
    final json = await _request('/api/user/playlist', {
      'uid': uid,
      'limit': 1000,
      'offset': 0,
      'includeVideo': true,
    }, _Scheme.weapi);
    final list = json['playlist'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(NetEasePlaylist.fromJson)
        .whereType<NetEasePlaylist>()
        .toList();
  }

  /// 歌单内的歌曲。走 eapi —— weapi 的 playlist/detail 对大歌单会截断。
  Future<List<NetEaseSong>> playlistTracks(int playlistId) async {
    final json = await _request('/api/v6/playlist/detail', {
      'id': playlistId,
      'n': 100000,
      's': 8,
    }, _Scheme.eapi);
    final playlist = json['playlist'];
    if (playlist is! Map) return const [];
    final tracks = playlist['tracks'] as List? ?? const [];
    return tracks
        .whereType<Map<String, dynamic>>()
        .map(NetEaseSong.fromJson)
        .whereType<NetEaseSong>()
        .toList();
  }

  /// 每日推荐歌曲。需要登录。
  Future<List<NetEaseSong>> dailyRecommend() async {
    final json = await _request(
      '/api/v3/discovery/recommend/songs',
      const {},
      _Scheme.weapi,
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final songs = data['dailySongs'] as List? ?? const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(NetEaseSong.fromJson)
        .whereType<NetEaseSong>()
        .toList();
  }

  /// 播放记录。[weekly] 为 true 取一周内，否则取全部历史。
  Future<List<NetEaseSong>> playRecord(int uid, {bool weekly = false}) async {
    final type = weekly ? 1 : 0;
    final json = await _request('/api/v1/play/record', {
      'uid': uid,
      'type': type,
      // 两种类型的返回上限不同，照网易云客户端的取值。
      'limit': weekly ? 100 : 1000,
    }, _Scheme.weapi);
    // 周榜在 weekData、全部在 allData，键名跟着 type 变。
    final list = json[weekly ? 'weekData' : 'allData'] as List? ?? const [];
    final songs = <NetEaseSong>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final songJson = item['song'];
      if (songJson is! Map<String, dynamic>) continue;
      final song = NetEaseSong.fromJson(songJson);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  /// 推荐歌单。不需要登录。
  Future<List<NetEasePlaylist>> personalizedPlaylists({int limit = 20}) async {
    final json = await _request('/api/personalized/playlist', {
      'limit': limit,
      'n': limit,
    }, _Scheme.weapi);
    final list = json['result'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(NetEasePlaylist.fromPersonalizedJson)
        .whereType<NetEasePlaylist>()
        .toList();
  }

  /// 推荐新歌。不需要登录。
  ///
  /// 返回里歌曲有时裹在 `song` 字段下、有时就是条目本身，两种都认。
  Future<List<NetEaseSong>> newSongs({int limit = 20}) async {
    final json = await _request('/api/personalized/newsong', {
      'type': 0,
      'limit': limit,
    }, _Scheme.weapi);
    final list = json['result'] as List? ?? const [];
    final songs = <NetEaseSong>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final nested = item['song'];
      final song = nested is Map<String, dynamic>
          ? NetEaseSong.fromJson(nested)
          : NetEaseSong.fromJson(item);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  /// 私人 FM。需要登录，每次返回几首，播完再取。
  Future<List<NetEaseSong>> personalFm() async {
    final json = await _request('/api/v1/radio/get', const {}, _Scheme.weapi);
    final data = json['data'] as List? ?? const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(NetEaseSong.fromJson)
        .whereType<NetEaseSong>()
        .toList();
  }

  /// 红心 / 取消红心。
  ///
  /// 网易云这个接口对参数形状不稳定，按顺序试三种，任一返回 200 即成功
  /// （做法取自 Beans-Music 1.5.8 的修复）。
  Future<bool> like(int songId, {required bool liked}) async {
    final time = DateTime.now().millisecondsSinceEpoch.toString();
    final payloads = <Map<String, dynamic>>[
      {'alg': 'itembased', 'trackId': songId, 'like': liked, 'time': time},
      {'trackId': songId, 'like': liked},
      {'songId': songId, 'like': liked},
    ];
    for (final payload in payloads) {
      try {
        final json = await _request(
          '/api/song/like?t=$liked',
          payload,
          _Scheme.weapi,
        );
        if (json['code'] == 200) return true;
      } on NetEaseApiException catch (e) {
        debugPrint('[NetEase] like 尝试失败：${e.message}');
      }
    }
    return false;
  }
}
