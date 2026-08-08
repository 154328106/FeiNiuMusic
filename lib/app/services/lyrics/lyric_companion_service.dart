import 'package:dio/dio.dart';

import '../../state/settings_lyric_companion.dart';
import '../feiniu/api_client.dart';

/// FnMusicLyricsEditor 配套歌词服务。
///
/// 配套应用运行在飞牛 NAS 上（监听 38200 端口），提供 HTTP 写歌词：
/// - **读取歌词**：用飞牛音乐服务原本的接口（`FeiNiuApiClient.getLyricText`），
///   无需第三方；
/// - **写入歌词**：`POST /music/api/v1/lyric/list` body `{guid, content}`
///   （配套应用，X-API-Key 必填）。
///
/// 仅非中继（relayMode == false）连接下可用：中继时 NAS 内网端口不暴露。
/// 基础 URL 取 `FeiNiuApiClient.instance.baseUrl` 的主机 + `:38200`。
class LyricCompanionService {
  LyricCompanionService._internal();

  static final LyricCompanionService instance = LyricCompanionService._internal();

  static const int port = 38200;
  static const String _apiPath = '/music/api/v1/lyric/list';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.json,
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 当前是否可用（非中继连接 + 已配置密钥）。
  bool get available {
    final api = FeiNiuApiClient.instance;
    return !api.relayMode && api.baseUrl.isNotEmpty;
  }

  /// 构造配套应用基础 URL：`http://<NAS-host>:38200`。
  ///
  /// NAS-host 取自 `FeiNiuApiClient.baseUrl` 的主机部分。仅非 relay 时有效。
  String? get baseUrl {
    final api = FeiNiuApiClient.instance;
    if (api.relayMode || api.baseUrl.isEmpty) return null;
    final host = Uri.tryParse(api.baseUrl)?.host;
    if (host == null || host.isEmpty) return null;
    return 'http://$host:$port';
  }

  /// 健康探测：验证配套应用是否在 NAS 上运行。
  ///
  /// 配套应用的 `/health` 无论密钥如何都返回 `code:0`（服务可达），
  /// `data.auth` 区分三态："ok"（匹配）/ "missing"（未传密钥）/
  /// "invalid"（密钥错误）。因此：
  /// - 服务可达（code==0）→ 默认返回 null（探测成功）；
  /// - [checkKey] 为 true 时校验密钥：`auth == "ok"` 通过，否则区分
  ///   "missing"（服务端配了密钥但没传）与 "invalid"（密钥错误）；
  /// - 端口不可达 / 超时 → 返回「未检测到」。
  Future<String?> probe(String apiKey, {bool checkKey = false}) async {
    final base = baseUrl;
    if (base == null) return '中继连接下不可用';
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/health',
        options: Options(
          headers: {
            if (apiKey.isNotEmpty) 'X-API-Key': apiKey,
          },
        ),
      );
      final code = response.data?['code'];
      if (code == 0) {
        final data = response.data?['data'] as Map<String, dynamic>?;
        if (!checkKey) return null;
        final auth = data?['auth'];
        if (auth == 'ok') return null;
        return auth == 'missing'
            ? '服务端已配置密钥，请设置 X-API-Key'
            : '密钥无效（认证失败）';
      }
      if (response.statusCode == 401) return '密钥无效（HTTP 401）';
      return '服务异常（${response.statusCode}）';
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        return '未检测到 NAS 上运行的 FnMusicLyricsEditor';
      }
      return '连接失败：${e.message}';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  /// 读取歌词（LRC 文本）。
  ///
  /// 用飞牛音乐服务原本的接口（`FeiNiuApiClient.getLyricText`），无需第三方。
  /// 无歌词返回空字符串。
  Future<String> getLyrics(String trackGuid) async {
    final api = FeiNiuApiClient.instance;
    return await api.getLyricText(trackGuid) ?? '';
  }

  /// 写入歌词，成功后重新读取验证。
  Future<void> saveLyrics(String guid, String content) async {
    final base = baseUrl;
    if (base == null) throw StateError('中继连接下不可用');
    final response = await _dio.post<Map<String, dynamic>>(
      '$base$_apiPath',
      data: {'guid': guid, 'content': content},
      options: Options(
        headers: {
          ..._authHeaders(),
          'Content-Type': 'application/json',
        },
      ),
    );
    final code = response.data?['code'];
    if (code != 0) {
      throw Exception(response.data?['msg'] ?? '写入歌词失败');
    }
    // 保存后重新读取验证（配套应用可能规范化歌词内容，仅确认可读回非空）
    final verify = await getLyrics(guid);
    if (verify.isEmpty) {
      throw Exception('写入后读取验证失败');
    }
  }

  Map<String, String> _authHeaders() {
    return {
      'X-API-Key': LyricCompanionSettings.apiKey.value,
    };
  }
}
