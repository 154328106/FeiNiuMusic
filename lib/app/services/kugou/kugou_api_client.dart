import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// 带前缀导入：pointycastle 和 crypto 都导出 Digest，裸导会撞名。
import 'package:pointycastle/export.dart' as pc;

import 'kugou_auth.dart';
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

  /// 网关接口用的客户端标识（和取址那套 appid/clientver 不是一回事）。
  static const String _gwAppid = '3116';
  static const String _gwClientver = '11440';
  static const String _qrAppid = '1001';
  static const String _qrSrcAppid = '2919';
  static const String _androidSignKey = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
  static const String _webSignKey = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
  static const String _androidUa =
      'Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi';

  static const String _gateway = 'https://gateway.kugou.com';
  static const String _loginBase = 'https://login-user.kugou.com';
  static const String _userService = 'https://userservice.kugou.com';

  /// 设备 mid：签名的一部分，来自 [KugouAuth]，跨启动固定。
  ///
  /// 之前这里是 `md5(random)`，每开一次 App 就换一台「新设备」——酷狗那边
  /// 的风控和会员判定全对不上号。
  String get _mid => KugouAuth.instance.mid;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {'User-Agent': _browserUa},
    ),
  );

  Future<Map<String, dynamic>> _getJson(
    String url, {
    String? ua,
    Map<String, String>? headers,
  }) async {
    final Response<String> response;
    final merged = <String, String>{
      if (ua != null) 'User-Agent': ua,
      ...?headers,
    };
    try {
      response = await _dio.get<String>(
        url,
        options: merged.isEmpty ? null : Options(headers: merged),
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
    final auth = KugouAuth.instance;
    // 登录后带上 userid / token / vipType：会员曲的地址是按账号发的，
    // 匿名请求拿到的永远是 status=2。key 里的 userid 也要跟着换。
    final userId = auth.isLoggedIn.value ? auth.userId : '0';
    final h = hash.toUpperCase();
    final key = _md5Hex('$h$_playSalt$_appid$_mid$userId');
    final params = <String, String>{
      'cmd': '26',
      'hash': h,
      'behavior': 'play',
      'appid': _appid,
      'pid': '2',
      'mid': _mid,
      'userid': userId,
      'version': _clientver,
      'vipType': '${auth.vipType}',
      'token': auth.isLoggedIn.value ? auth.token : '0',
      'key': key,
      if (albumAudioId != null && albumAudioId.isNotEmpty)
        'album_audio_id': albumAudioId,
      if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final json = await _getJson(
      'https://trackercdn.kugou.com/i/v2/?$query',
      headers: {
        if (auth.cookieHeader.isNotEmpty) 'Cookie': auth.cookieHeader,
        'dfid': auth.dfid,
        'mid': _mid,
      },
    );

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


  // ---------------------------------------------------------------------
  // 网关：签名请求 / 扫码登录 / 云端歌单
  //
  // 上面那些接口全是免登录的纯 GET 老接口，这一段不一样：走 gateway，
  // 参数要按 key 排序拼起来算 MD5 签名，登录后还要带 Cookie。
  // ---------------------------------------------------------------------

  Map<String, String> _baseParams() {
    final auth = KugouAuth.instance;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'dfid': auth.dfid,
      'mid': auth.mid,
      'uuid': '-',
      'appid': _gwAppid,
      'clientver': _gwClientver,
      'clienttime': '$now',
      if (auth.isLoggedIn.value) 'token': auth.token,
      if (auth.isLoggedIn.value) 'userid': auth.userId,
    };
  }

  /// 签名 = MD5(key + 按字段名排序拼接的 params + body + key)。
  /// 网页端那套（[web] 为 true）不把 body 算进去。
  static String _signature(
    Map<String, String> params,
    String body, {
    required bool web,
  }) {
    final key = web ? _webSignKey : _androidSignKey;
    final sorted = params.keys.toList()..sort();
    final joined = sorted.map((k) => '$k=${params[k]}').join();
    return _md5Hex('$key$joined${web ? '' : body}$key');
  }

  Future<Map<String, dynamic>> _gateway(
    String path, {
    String? baseUrl,
    String method = 'GET',
    bool web = false,
    Map<String, String> params = const {},
    Map<String, dynamic>? data,
    Uint8List? rawBody,
    Map<String, String> headers = const {},
  }) async {
    final auth = KugouAuth.instance;
    final all = _baseParams()..addAll(params);
    final bodyText = data == null ? '' : jsonEncode(data);
    final body = rawBody ?? (data == null ? null : utf8.encode(bodyText));
    all['signature'] = _signature(all, bodyText, web: web);
    final query = all.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final merged = <String, String>{
      'User-Agent': _androidUa,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'dfid': auth.dfid,
      'mid': auth.mid,
      'clienttime': all['clienttime'] ?? '',
      if (auth.cookieHeader.isNotEmpty) 'Cookie': auth.cookieHeader,
      ...headers,
    };
    final url = '${baseUrl ?? _gateway}$path?$query';
    if (method == 'GET') return _getJson(url, headers: merged);
    final Response<String> response;
    try {
      response = await _dio.post<String>(
        url,
        data: body,
        options: Options(headers: merged),
      );
    } on DioException catch (e) {
      throw KugouApiException('网络请求失败：${e.message ?? e.type.name}');
    }
    final decoded = jsonDecode(response.data ?? '{}');
    if (decoded is! Map<String, dynamic>) {
      throw KugouApiException('响应格式异常');
    }
    return decoded;
  }

  /// 生成登录二维码。返回的 key 既是轮询凭据，也是二维码里的内容。
  Future<String> qrKey() async {
    await KugouAuth.instance.ensureLoaded();
    final json = await _gateway(
      '/v2/qrcode',
      baseUrl: _loginBase,
      web: true,
      params: {
        'appid': _qrAppid,
        'type': '1',
        'plat': '4',
        'qrcode_txt':
            'https://h5.kugou.com/apps/loginQRCode/html/index.html'
            '?appid=$_gwAppid&',
        'srcappid': _qrSrcAppid,
      },
      headers: {'User-Agent': _browserUa, 'x-router': 'login-user.kugou.com'},
    );
    final key = _deepString(json, const ['qrcode', 'key']);
    if (key.isEmpty) throw KugouApiException('二维码生成失败');
    return key;
  }

  /// 轮询扫码结果。
  Future<KugouScanResult> pollQr(String key) async {
    final json = await _gateway(
      '/v2/get_userinfo_qrcode',
      baseUrl: _loginBase,
      web: true,
      params: {
        'plat': '4',
        'appid': _gwAppid,
        'srcappid': _qrSrcAppid,
        'qrcode': key,
      },
      headers: {'User-Agent': _browserUa, 'x-router': 'login-user.kugou.com'},
    );
    final token = _deepString(json, const [
      'token',
      'user_token',
      'access_token',
    ]);
    final userId = _digits(
      _deepString(json, const ['userid', 'user_id', 'uid', 'kugouid']),
    );
    if (token.isEmpty || userId.isEmpty) {
      // 状态码：1 等待扫码，2 已扫待确认，3 已过期。
      final status = _deepInt(json, const ['status']);
      if (status == 2) return const KugouScanResult(KugouScanState.scanned);
      if (status == 3) return const KugouScanResult(KugouScanState.expired);
      return const KugouScanResult(KugouScanState.waiting);
    }
    final nick = _deepString(json, const [
      'nickname',
      'nick',
      'username',
      'uname',
    ]);
    final avatar = _deepString(json, const ['pic', 'avatar', 'img']);
    final vip = _deepInt(json, const [
      'vip_type',
      'vipType',
      'viptype',
      'is_vip',
    ]);
    await KugouAuth.instance.saveLogin(
      userId: userId,
      token: token,
      nickname: nick,
      avatar: avatar,
      vipType: vip,
    );
    await registerDevice();
    return KugouScanResult(
      KugouScanState.success,
      nickname: nick.isEmpty ? '酷狗用户 $userId' : nick,
    );
  }

  /// 注册设备换 dfid。
  ///
  /// 不做也能登录，但会员曲的取址接口认这个值 —— 少了它，登录了照样
  /// status=2。这是整个酷狗接入里唯一需要真加密的地方：设备信息用随机
  /// 口令做 AES-CBC，口令本身再用酷狗的 RSA 公钥加密后放进 query。
  Future<void> registerDevice() async {
    final auth = KugouAuth.instance;
    if (!auth.isLoggedIn.value) return;
    try {
      final rand = Random.secure();
      const pool = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final aesKey = List.generate(
        6,
        (_) => pool[rand.nextInt(pool.length)],
      ).join();
      final payload = utf8.encode(
        jsonEncode({
          'appid': int.parse(_gwAppid),
          'clientver': int.parse(_gwClientver),
          'mid': auth.mid,
          'platform': 'android',
          'gyroscope': false,
        }),
      );
      final encrypted = _aesCbcEncrypt(Uint8List.fromList(payload), aesKey);
      final p = utf8.encode(
        jsonEncode({
          'aes': aesKey,
          'uid': int.tryParse(auth.userId) ?? 0,
          'token': auth.token,
        }),
      );
      final rsa = _rsaEncrypt(Uint8List.fromList(p));
      final json = await _gateway(
        '/risk/v2/r_register_dev',
        baseUrl: _userService,
        method: 'POST',
        params: {'part': '1', 'platid': '1', 'p': _hex(rsa)},
        rawBody: encrypted,
        headers: {
          'x-router': 'userservice.kugou.com',
          'Content-Type': 'application/octet-stream',
        },
      );
      final dfid = _deepString(json, const ['dfid']);
      await auth.saveDfid(dfid);
      debugPrint('[Kugou] 设备注册：dfid=${dfid.isEmpty ? '未返回' : '已获取'}');
    } catch (e) {
      // 拿不到 dfid 只影响会员曲成功率，不该让登录整个失败。
      debugPrint('[Kugou] 设备注册失败：$e');
    }
  }

  /// 登录用户的云端歌单（含「我喜欢」）。
  Future<List<KugouPlaylist>> userPlaylists({int limit = 50}) async {
    final auth = KugouAuth.instance;
    if (!auth.isLoggedIn.value) return const [];
    final json = await _gateway(
      '/v7/get_all_list',
      method: 'POST',
      params: {
        'total_ver': '979',
        'type': '2',
        'page': '1',
        'pagesize': '200',
        'userid': auth.userId,
        'token': auth.token,
      },
      data: {
        'total_ver': 979,
        'type': 2,
        'page': 1,
        'pagesize': 200,
        'userid': int.tryParse(auth.userId) ?? 0,
        'token': auth.token,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
    final raw = _deepList(json, const ['info', 'list', 'lists']);
    final result = <KugouPlaylist>[];
    final seen = <int>{};
    for (final item in raw.whereType<Map>()) {
      final id = _numOf(item, const ['listid', 'id', 'specialid']);
      if (id <= 0 || !seen.add(id)) continue;
      final name = _strOf(item, const ['name', 'listname', 'specialname']);
      final cover = _strOf(
        item,
        const ['pic', 'img', 'list_pic', 'cover'],
      ).replaceAll('{size}', '400');
      result.add(
        KugouPlaylist(
          id: id,
          name: name.isEmpty ? '酷狗歌单' : name,
          coverUrl: cover.isEmpty ? null : cover,
          trackCount: _numOf(item, const ['count', 'song_count', 'total']),
        ),
      );
      if (result.length >= limit) break;
    }
    debugPrint('[Kugou] 云端歌单 ${result.length} 个');
    return result;
  }

  /// 云端歌单里的歌。分页拉，一页 200。
  Future<List<KugouSong>> userPlaylistSongs(
    int listId, {
    int limit = 300,
  }) async {
    final auth = KugouAuth.instance;
    if (!auth.isLoggedIn.value) return const [];
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= 5; page++) {
      final json = await _gateway(
        '/v4/get_list_all_file',
        method: 'POST',
        params: {
          'listid': '$listId',
          'page': '$page',
          'pagesize': '200',
          'userid': auth.userId,
          'token': auth.token,
        },
        data: {
          'listid': '$listId',
          'page': page,
          'pagesize': 200,
          'area_code': 1,
          'show_relate_goods': 0,
          'allplatform': 1,
          'show_cover': 1,
          'type': 0,
          'userid': int.tryParse(auth.userId) ?? 0,
          'token': auth.token,
        },
        headers: {'x-router': 'cloudlist.service.kugou.com'},
      );
      final rows = _deepList(json, const ['songs', 'info', 'list', 'files']);
      all.addAll(rows.whereType<Map<String, dynamic>>());
      if (rows.length < 200 || all.length >= limit) break;
    }
    debugPrint('[Kugou] 歌单 $listId 共 ${all.length} 首');
    return _toSongs(all.take(limit).toList());
  }

  // ------------------------- 网关用到的小工具 -------------------------

  static Uint8List _aesCbcEncrypt(Uint8List input, String password) {
    // 口令补齐到 32 字节，IV 全零 —— 照抄官方端。
    final key = Uint8List(32);
    final iv = Uint8List(16);
    final pwd = utf8.encode(password);
    for (var i = 0; i < pwd.length && i < 32; i++) {
      key[i] = pwd[i];
    }
    final cipher = pc.PaddedBlockCipherImpl(
      pc.PKCS7Padding(),
      pc.CBCBlockCipher(pc.AESEngine()),
    );
    cipher.init(
      true,
      pc.PaddedBlockCipherParameters<pc.CipherParameters, pc.CipherParameters>(
        pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(input);
  }

  /// 酷狗的 RSA 公钥模数（1024 位）。公开信息，不是密钥。
  static final BigInt _rsaModulus = BigInt.parse(
    'c40a2d0da76511f3bb1cc2bbd3afbd8bea83b4d6b05b6c13eb8920c53f1af767'
    '9b32ba0d0edb843240ef1b836efed3ee240734c14c1399fd6594d16af22f5252'
    '5d14d72e0155c6dcc8638d4f7bb94f3a0b1f4c29f991972f2a160a25eb0a9e72'
    '4336be7f69bbd319ffab1c6dd8470b021dc434f3faba89f4a2a01b33bdbdd08b',
    radix: 16,
  );

  static Uint8List _rsaEncrypt(Uint8List input) {
    final engine = pc.PKCS1Encoding(pc.RSAEngine());
    engine.init(
      true,
      pc.PublicKeyParameter<pc.RSAPublicKey>(
        pc.RSAPublicKey(_rsaModulus, BigInt.from(65537)),
      ),
    );
    return engine.process(input);
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _digits(String input) => input.replaceAll(RegExp('[^0-9]'), '');

  /// 酷狗的返回层级不固定（data / info / 顶层都可能），按字段名深搜。
  static String _deepString(Object? node, List<String> names) {
    final found = _deepFind(node, names, 0);
    return found == null ? '' : found.toString();
  }

  static int _deepInt(Object? node, List<String> names) {
    final found = _deepFind(node, names, 0);
    if (found is num) return found.toInt();
    return int.tryParse('$found') ?? 0;
  }

  static List<Object?> _deepList(Object? node, List<String> names) {
    final found = _deepFind(node, names, 0);
    return found is List ? found : const [];
  }

  static Object? _deepFind(Object? node, List<String> names, int depth) {
    if (depth > 6) return null;
    if (node is Map) {
      for (final name in names) {
        final value = node[name];
        if (value != null && value != '' && value != 0) return value;
      }
      for (final value in node.values) {
        final found = _deepFind(value, names, depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _deepFind(value, names, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  static int _numOf(Map<Object?, Object?> raw, List<String> names) {
    for (final name in names) {
      final value = raw[name];
      if (value is num) return value.toInt();
      final parsed = int.tryParse('${value ?? ''}');
      if (parsed != null) return parsed;
    }
    return 0;
  }

  static String _strOf(Map<Object?, Object?> raw, List<String> names) {
    for (final name in names) {
      final value = raw[name];
      if (value != null && '$value'.isNotEmpty) return '$value';
    }
    return '';
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
