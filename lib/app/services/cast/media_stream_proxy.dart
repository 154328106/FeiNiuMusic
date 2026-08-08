import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 本地 HTTP 代理：把需要 Cookie 认证的飞牛音频流转成 DLNA 渲染器可直连的匿名 URL。
///
/// 飞牛音频流（`/track/stream`、转码 HLS）都要携带 `Cookie: music-token=...`
/// （+ 中继 `mode=relay`、安全码）才能访问，而 DLNA 渲染器无法发送自定义
/// Cookie。因此本机起一个临时 HTTP 服务，把流 URL「换签」为
/// `http://<本机LAN IP>:<port>/m/<token>...`：
///
/// - 渲染器请求该地址时，代理携带认证头转发到上游；
/// - 上游是 HLS m3u8 时，代理把其中相对分片地址改写成经本代理的绝对地址
///   （渲染器才能拉到分片）；
/// - Range 请求（拖动进度）原样透传。
///
/// 用随机端口（0）启动，与 `LoginPairServer`（同为端口 0）天然并存。
class MediaStreamProxy {
  MediaStreamProxy._();

  static final MediaStreamProxy instance = MediaStreamProxy._();

  static const int _maxRedirects = 5;

  HttpServer? _server;
  String? _token;
  String _proxyBase = '';
  String _upstreamUrl = '';
  Map<String, String> _upstreamHeaders = const {};

  /// 测试专用：强制代理基址使用回环地址（避免测试环境连接到真实 LAN IP）。
  @visibleForTesting
  static bool forceLoopbackBase = false;

  bool get isRunning => _server != null;

  String? get token => _token;

  String? get proxyBase => _proxyBase.isEmpty ? null : _proxyBase;

  /// 当前代理是否已注册了可用的上游媒体流。
  bool get hasMedia => _upstreamUrl.isNotEmpty;

  /// 启动本地代理服务（幂等）。成功返回 `http://<LAN IP>:<port>`，失败返回 null。
  Future<String?> start() async {
    if (_server != null) return _proxyBase;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      _token = _generateToken();
      _proxyBase = await _buildBaseUrl(server.port);
      server.listen(
        _handle,
        onError: (Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('[MediaStreamProxy] server error: $e\n$st');
          }
        },
      );
      if (kDebugMode) {
        debugPrint('[MediaStreamProxy] started at $_proxyBase');
      }
      return _proxyBase;
    } catch (e) {
      if (kDebugMode) debugPrint('[MediaStreamProxy] start failed: $e');
      _server = null;
      _token = null;
      _proxyBase = '';
      return null;
    }
  }

  /// 注册一条上游媒体流，返回渲染器可用的代理 URL（`http://<ip>:<port>/m/<token>`）。
  ///
  /// 同一时刻只代理一条流（单投屏会话）：注册新流会替换旧流。
  Future<String?> registerMedia(
    String upstreamUrl, {
    Map<String, String> headers = const {},
  }) async {
    final base = await start();
    if (base == null || _token == null) return null;
    _upstreamUrl = upstreamUrl;
    _upstreamHeaders = headers;
    return '$base/m/$_token';
  }

  /// 清空当前注册的媒体流（断开投屏时调用）。代理服务本身保留。
  void unregisterMedia() {
    _upstreamUrl = '';
    _upstreamHeaders = const {};
  }

  /// 停止代理服务（幂等）。断开投屏并释放端口。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _proxyBase = '';
    _upstreamUrl = '';
    _upstreamHeaders = const {};
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final pathSegments = request.uri.pathSegments;
      // 路由：/m/<token>[/...]?u=<目标URL>
      if (pathSegments.length < 2 ||
          pathSegments[0] != 'm' ||
          pathSegments[1] != _token) {
        _respondNotFound(request);
        return;
      }
      final upstream = _upstreamUrl;
      if (upstream.isEmpty) {
        _respondNotFound(request);
        return;
      }

      // 分片/变体播放列表转发：/m/<token>?u=<urlencoded 绝对地址>
      final queryU = request.uri.queryParameters['u'];
      final target = (queryU != null && queryU.isNotEmpty)
          ? Uri.decodeComponent(queryU)
          : upstream;

      await _forward(request, target, _upstreamHeaders);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[MediaStreamProxy] handle error: $e');
      }
      _respondInternalError(request);
    }
  }

  /// 手动跟随重定向地把请求转发到 [target]，保持认证头；支持 Range 透传。
  ///
  /// 上游是 HLS m3u8（`application/vnd.apple.mpegurl`）时，读取全文并把相对
  /// 分片地址改写成经本代理的绝对地址后返回。
  Future<void> _forward(
    HttpRequest request,
    String target,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      var uri = Uri.parse(target);
      for (var hop = 0; hop < _maxRedirects; hop++) {
        final upReq = await client.openUrl(request.method, uri);
        // 注入认证头（Cookie / 安全码）
        for (final entry in headers.entries) {
          upReq.headers.set(entry.key, entry.value);
        }
        // 透传 Range（拖动进度）/ If-None-Match 等
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.isNotEmpty) {
          upReq.headers.set(HttpHeaders.rangeHeader, range);
        }

        final upResp = await upReq.close();

        // 手动跟随重定向（保持 Cookie）
        if (upResp.statusCode >= 300 && upResp.statusCode < 400) {
          final location = upResp.headers.value(HttpHeaders.locationHeader);
          if (location != null && location.isNotEmpty) {
            final next = uri.resolve(location);
            await upResp.drain<void>();
            uri = next;
            continue;
          }
        }

        final isM3u8 = _isM3u8(upResp, uri);
        if (isM3u8 && request.method != 'HEAD') {
          // HLS：读取 m3u8 文本，改写分片地址后整体返回
          final text = await upResp.transform(utf8.decoder).join();
          final rewritten = _rewriteM3u8(text, uri);
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          response.headers.set(HttpHeaders.contentTypeHeader,
              'application/vnd.apple.mpegurl; charset=utf-8');
          response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          response.write(rewritten);
          await response.close();
          return;
        }

        // 普通媒体流 / Range：透传状态、关键响应头，流式转发 body
        final response = request.response;
        response.statusCode = upResp.statusCode;
        _copyResponseHeaders(upResp, response);
        if (request.method == 'HEAD') {
          await response.close();
        } else {
          await response.addStream(upResp);
          await response.close();
        }
        return;
      }
      _respondInternalError(request);
    } finally {
      client.close(force: true);
    }
  }

  /// 判断上游响应是否为 HLS m3u8（按 Content-Type 或 URL 后缀）。
  bool _isM3u8(HttpClientResponse upResp, Uri uri) {
    final contentType = upResp.headers.value(HttpHeaders.contentTypeHeader);
    if (contentType != null) {
      final mime = contentType.split(';').first.trim().toLowerCase();
      if (mime == 'application/vnd.apple.mpegurl' ||
          mime == 'application/x-mpegurl') {
        return true;
      }
    }
    final path = uri.path.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// 把 m3u8 里的分片/变体/init 段地址改写成经本代理的绝对地址。
  ///
  /// - 非 `#` 开头的行（分片、变体播放列表地址）：相对地址先按 m3u8 所在 URL
  ///   解析成绝对地址，再编码进 `?u=`；
  /// - 标签行里的 `URI="..."`（`#EXT-X-MAP` 的 init 段、`#EXT-X-KEY`、变体
  ///   `#EXT-X-MEDIA` 等）：同样改写，保证渲染器能拉到所有子资源。
  String _rewriteM3u8(String text, Uri baseUri) {
    final token = _token;
    if (token == null || _proxyBase.isEmpty) return text;
    String proxyUrl(String abs) =>
        '$_proxyBase/m/$token?u=${Uri.encodeComponent(abs)}';
    final lines = text.split('\n');
    final buffer = StringBuffer();
    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('#')) {
        // 标签行：改写其中 URI="..." 引号内的资源地址
        buffer.writeln(_rewriteTagUris(rawLine, baseUri, proxyUrl));
        continue;
      }
      // 分片/变体：相对地址解析为绝对地址后走代理
      final abs = baseUri.resolve(trimmed).toString();
      buffer.writeln(proxyUrl(abs));
    }
    return buffer.toString();
  }

  /// 改写 m3u8 标签行里 `URI="..."` 引号内的资源地址（相对 → 经代理）。
  String _rewriteTagUris(
    String line,
    Uri baseUri,
    String Function(String abs) proxyUrl,
  ) {
    const marker = 'URI="';
    final idx = line.indexOf(marker);
    if (idx < 0) return line;
    final start = idx + marker.length;
    final end = line.indexOf('"', start);
    if (end <= start) return line;
    final raw = line.substring(start, end);
    if (raw.isEmpty) return line;
    final abs = baseUri.resolve(raw).toString();
    return line.replaceRange(start, end, proxyUrl(abs));
  }

  /// 复制上游响应头里与媒体投递相关的字段到代理响应。
  void _copyResponseHeaders(
    HttpClientResponse from,
    HttpResponse to,
  ) {
    const allowlist = <String>{
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.cacheControlHeader,
    };
    for (final allow in allowlist) {
      final value = from.headers.value(allow);
      if (value != null && value.isNotEmpty) {
        to.headers.set(allow, value);
      }
    }
  }

  void _respondNotFound(HttpRequest request) {
    final response = request.response;
    response.statusCode = HttpStatus.notFound;
    response.write('Not found');
    response.close();
  }

  void _respondInternalError(HttpRequest request) {
    final response = request.response;
    response.statusCode = HttpStatus.internalServerError;
    response.write('Proxy error');
    response.close();
  }

  String _generateToken() {
    final rnd = Random.secure();
    return List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// 构造代理对外基址：优先取本机局域网 IPv4（渲染器同网段可达），
  /// 取不到时回退 127.0.0.1（仅本机可用，投屏基本无意义，但可测）。
  static Future<String> _buildBaseUrl(int port) async {
    if (forceLoopbackBase) return 'http://127.0.0.1:$port';
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.')) continue; // APIPA / 链路本地
          ips.add(ip);
        }
      }
    } catch (_) {}
    if (ips.isEmpty) ips.add('127.0.0.1');
    return 'http://${ips.first}:$port';
  }
}
