import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

/// 单个 LX（洛雪）脚本音源的句柄。
///
/// **所有脚本共用一个 JS 运行时**（见 [_LxEngine]），本类只是按 scriptId 的轻量
/// 包装，转调共享引擎。
///
/// 为什么必须共享一个引擎：flutter_js 0.8.7 在 iOS（JavaScriptCore）上的
/// `sendMessage` 原生桥 `_sendMessageDartFunc` / `sendMessageBridgeFunction` 是
/// **static** 的，每 new 一个 JSCore 运行时都会把它覆盖成最后那个实例——于是所有
/// 运行时的 `sendMessage` 都被路由到最后创建的那个实例的通道表。多实例时，除最后
/// 一个脚本外，其它脚本的 HTTP / 取址结果回调全发错了实例 → 等待者永不完成 → 超时。
/// 现象正是「单源能取到、多源只命中一个或全军覆没」。串行化救不了（那是路由错，不是
/// 并发）。改成单引擎后，全程只有一个实例，路由不再错位；Android 的 QuickJS 本就
/// 按实例路由，单引擎同样正确且更省资源。
class LxScriptRuntime {
  LxScriptRuntime() : _scriptId = 'lx${++_idSeq}';

  static int _idSeq = 0;
  final String _scriptId;

  /// 脚本名（从 @name 注释尽力解析，仅展示用）。
  String name = '';

  /// 交给脚本的 `lx.currentScriptInfo`（头注释里的元信息 + 原文）。
  @visibleForTesting
  static Map<String, String> scriptInfo(String script) =>
      _LxEngine.scriptInfo(script);

  /// 脚本 send(inited) 声明的支持平台代号（如 wy/tx/kg/kw/mg）。
  List<String> get sources => _LxEngine.instance.sourcesOf(_scriptId);

  /// 加载脚本文本并等待其 `send(EVENT_NAMES.inited)`。返回是否成功 inited。
  Future<bool> load(String scriptText, {Duration? timeout}) {
    name = _LxEngine.parseName(scriptText) ?? name;
    return _LxEngine.instance.loadScript(
      _scriptId,
      scriptText,
      timeout: timeout,
    );
  }

  /// 调脚本取某首歌的可播放直链。[info] 是传给脚本的歌曲信息（songmid/hash 等）。
  Future<String?> getMusicUrl({
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
    bool priority = true,
  }) => _LxEngine.instance.getUrl(
    _scriptId,
    source: source,
    info: info,
    quality: quality,
    timeout: timeout,
    priority: priority,
  );

  /// 同 [getMusicUrl]，另外告诉调用方这次是不是**跑满超时**才放弃的
  /// （排队等待不算），以及脚本自己报的错（「没货」的理由）。
  /// 解灰链靠 timedOut 判断脚本后端是不是挂了；测试按钮把 error 显示出来。
  Future<({String? url, bool timedOut, String? error})> getMusicUrlTimed({
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
    bool priority = true,
  }) => _LxEngine.instance.getUrlTimed(
    _scriptId,
    source: source,
    info: info,
    quality: quality,
    timeout: timeout,
    priority: priority,
  );

  void dispose() => _LxEngine.instance.unloadScript(_scriptId);
}

/// 全应用唯一的 LX JS 引擎。持有唯一的 [JavascriptRuntime]，所有脚本在同一个
/// JS 上下文里按 scriptId 分隔（`globalThis.__lxScripts[scriptId]`）。
///
/// 取址全局串行（[_foreground] / [_backgroundTasks] 两级队列）：JS 引擎单线程驱动，一次只跑一个取址，避免 evaluate /
/// 微任务泵交叠。HTTP 回调与取址结果用全局自增 id 配对，和 scriptId 无关。
class _LxEngine {
  _LxEngine._();
  static final _LxEngine instance = _LxEngine._();

  final JavascriptRuntime _rt = getJavascriptRuntime();
  final Dio _dio = Dio(
    BaseOptions(
      // 脚本自己判断状态码；重定向默认跟随，脚本可用 options 关掉。
      validateStatus: (_) => true,
      // 连接超时砍到 5s：聚合脚本里常有死域名（如 api.xinghai.com），15s 连接
      // 超时会让一首歌卡半分钟、表现成「换一首就播不了」。活站握手都在 1s 内，
      // 5s 足够；死站 5s 快速失败、让链条尽快走到能用的后端。
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  bool _booted = false;
  int _reqSeq = 0;
  Timer? _pump;

  /// 取址串行闸：两级队列，前台（正在点的歌、测试脚本）永远排在后台预取前面。
  /// 引擎仍然一次只跑一个取址。
  final Queue<_LxTask> _foreground = Queue<_LxTask>();
  final Queue<_LxTask> _backgroundTasks = Queue<_LxTask>();
  bool _draining = false;

  /// 刚跑完的那个取址是不是等满了超时（队列串行，跑完立刻读，不会串）。
  bool _lastTimedOut = false;

  /// 刚跑完的那个取址，脚本自己 reject 的理由（同样靠串行保证不串）。
  String? _lastError;

  final Map<int, Completer<String?>> _invokeWaiters = {};
  final Map<String, Completer<void>> _initedWaiters = {};
  final Map<String, List<String>> _sources = {};

  List<String> sourcesOf(String scriptId) => _sources[scriptId] ?? const [];

  void _boot() {
    if (_booted) return;
    _booted = true;
    _registerChannels();
    _rt.evaluate(_hostShim);
  }

  Future<bool> loadScript(
    String scriptId,
    String scriptText, {
    Duration? timeout,
  }) async {
    try {
      _boot();
      final inited = Completer<void>();
      _initedWaiters[scriptId] = inited;
      // 用户脚本引用裸 `lx`——包进一层函数、以参数 lx 遮蔽，就能给每个脚本各自的
      // 宿主对象、各自的 handlers。脚本原文直接内联（和洛雪注入方式一致），末尾补
      // 换行以终结可能的行尾注释。
      final wrapped =
          'globalThis.__lxDefineScript(${jsonEncode(scriptId)}, '
          '${jsonEncode(scriptInfo(scriptText))}, function(lx){\n'
          '$scriptText\n});';
      _rt.evaluate(wrapped);
      _startPump();
      await inited.future.timeout(timeout ?? const Duration(seconds: 8));
      return true;
    } catch (e) {
      debugPrint('[LX] 脚本加载失败（$scriptId）：$e');
      _initedWaiters.remove(scriptId);
      return false;
    }
  }

  void unloadScript(String scriptId) {
    _initedWaiters.remove(scriptId);
    _sources.remove(scriptId);
    try {
      _rt.evaluate('globalThis.__lxUnload(${jsonEncode(scriptId)});');
    } catch (_) {}
  }

  /// 取某脚本的直链。按 [priority] 进前台/后台队列，前一个取址彻底结束后再碰引擎。
  Future<String?> getUrl(
    String scriptId, {
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
    bool priority = true,
  }) => getUrlTimed(
    scriptId,
    source: source,
    info: info,
    quality: quality,
    timeout: timeout,
    priority: priority,
  ).then((r) => r.url);

  Future<({String? url, bool timedOut, String? error})> getUrlTimed(
    String scriptId, {
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
    bool priority = true,
  }) {
    final task = _LxTask(
      () => _getUrlLocked(
        scriptId,
        source: source,
        info: info,
        quality: quality,
        timeout: timeout,
      ),
    );
    (priority ? _foreground : _backgroundTasks).add(task);
    unawaited(_runQueue());
    return task.result.future.then(
      (u) => (url: u, timedOut: task.timedOut, error: task.error),
    );
  }

  Future<void> _runQueue() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_foreground.isNotEmpty || _backgroundTasks.isNotEmpty) {
        if (_foreground.isEmpty) {
          // 前台一首歌会依次问多个脚本，两次之间留一点空，别让后台任务插进来
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (_foreground.isEmpty && _backgroundTasks.isEmpty) break;
        }
        final task = _foreground.isNotEmpty
            ? _foreground.removeFirst()
            : _backgroundTasks.removeFirst();
        _lastTimedOut = false;
        _lastError = null;
        try {
          final url = await task.run();
          task.timedOut = _lastTimedOut;
          task.error = _lastError;
          task.result.complete(url);
        } catch (_) {
          task.timedOut = _lastTimedOut;
          task.error = _lastError;
          if (!task.result.isCompleted) task.result.complete(null);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<String?> _getUrlLocked(
    String scriptId, {
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
  }) async {
    final reqId = ++_reqSeq;
    final completer = Completer<String?>();
    _invokeWaiters[reqId] = completer;
    _startPump();
    // 洛雪(LX)约定：musicUrl 请求的 info 是 { type: 音质, musicInfo: {歌曲对象} }，
    // 脚本按 info.musicInfo / info.type 取。平铺会让脚本读 info.musicInfo 取到
    // undefined → 发空 id → 后端一律「无货」。
    final payload = jsonEncode({
      'action': 'musicUrl',
      'source': source,
      'info': {'type': quality, 'musicInfo': info},
    });
    try {
      debugPrint('[LX] invoke $scriptId reqId=$reqId source=$source');
      _rt.evaluate(
        'globalThis.__lxInvoke(${jsonEncode(scriptId)}, $reqId, $payload);',
      );
      _drain();
      return await completer.future.timeout(
        timeout ?? const Duration(seconds: 10),
      );
    } catch (e) {
      if (e is TimeoutException) _lastTimedOut = true;
      debugPrint('[LX] getMusicUrl 失败：$e');
      return null;
    } finally {
      _invokeWaiters.remove(reqId);
      if (_invokeWaiters.isEmpty && _initedWaiters.isEmpty) {
        _pump?.cancel();
        _pump = null;
      }
    }
  }

  // ---- 内部 ----

  /// 周期性泵 QuickJS 的 Promise/microtask 任务队列（JSCore 由系统泵，调用它
  /// 无害）。有未完成的取址或加载时才需要。
  void _startPump() {
    _pump ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      _drain();
      if (_invokeWaiters.isEmpty && _initedWaiters.isEmpty) {
        _pump?.cancel();
        _pump = null;
      }
    });
  }

  void _drain() {
    try {
      var n = 0;
      while (_rt.executePendingJob() > 0 && n++ < 1000) {}
    } catch (_) {}
  }

  void _registerChannels() {
    // 脚本发起的 HTTP：Dart 异步请求完，evaluate 把结果灌回 JS 的回调。
    _rt.onMessage('lx_http', (dynamic args) {
      final map = _asMap(args);
      final id = map['id'];
      final url = (map['url'] ?? '').toString();
      final options = _asMap(map['options']);
      debugPrint('[LX] lx_http id=$id url=$url');
      _doHttp(id, url, options);
      return null;
    });
    // 取址处理器的结果（Promise resolve/reject 后脚本发回来）。全局 reqId 配对。
    _rt.onMessage('lx_result', (dynamic args) {
      final map = _asMap(args);
      final id = map['reqId'];
      debugPrint(
        '[LX] lx_result reqId=$id url?=${(map['url'] ?? '').toString().isNotEmpty} err=${map['err']}',
      );
      final waiter = id is int ? _invokeWaiters[id] : null;
      if (waiter != null && !waiter.isCompleted) {
        final err = map['err'];
        if (err != null && err.toString().isNotEmpty) {
          _lastError = err.toString();
        }
        final url = map['url'];
        waiter.complete(url is String && url.isNotEmpty ? url : null);
      }
      return null;
    });
    // 脚本声明支持的源（带 scriptId）。
    _rt.onMessage('lx_inited', (dynamic args) {
      final map = _asMap(args);
      final scriptId = (map['scriptId'] ?? '').toString();
      final list = map['sources'];
      List<String> srcs = const [];
      if (list is Map) {
        srcs = list.keys.map((e) => e.toString()).toList();
      } else if (list is List) {
        srcs = list.map((e) => e.toString()).toList();
      }
      if (scriptId.isNotEmpty) _sources[scriptId] = srcs;
      final w = _initedWaiters.remove(scriptId);
      if (w != null && !w.isCompleted) w.complete();
      return null;
    });
    _rt.onMessage('lx_log', (dynamic args) {
      debugPrint('[LX脚本] ${_asMap(args)['msg']}');
      return null;
    });
  }

  Future<void> _doHttp(
    dynamic id,
    String url,
    Map<String, dynamic> options,
  ) async {
    try {
      final method = (options['method'] ?? 'GET').toString().toUpperCase();
      final headers = <String, dynamic>{};
      final rawHeaders = options['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) => headers[k.toString()] = v);
      }
      final form = options['form'];
      dynamic body = options['body'] ?? form ?? options['data'];
      debugPrint('[LX] http $method $url');
      // 洛雪的 `form` 是表单（x-www-form-urlencoded）。以前原样交给 dio，dio 拿到
      // Map 默认按 JSON 发，服务端读不到参数。其余按原样（字符串 / JSON）交给 dio。
      final isForm = form is Map && options['body'] == null;
      final timeoutMs = options['timeout'];
      final resp = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          contentType: isForm ? Headers.formUrlEncodedContentType : null,
          responseType: ResponseType.plain,
          followRedirects: options['follow_max'] != 0,
          // 脚本自己给的超时（毫秒）：有的脚本靠它快速放弃死站
          receiveTimeout: timeoutMs is num && timeoutMs > 0
              ? Duration(milliseconds: timeoutMs.toInt())
              : null,
        ),
      );
      // lx 约定 resp.body：是 JSON 就给对象，否则给字符串。
      dynamic parsedBody = resp.data;
      if (resp.data is String) {
        final s = resp.data as String;
        try {
          parsedBody = jsonDecode(s);
        } catch (_) {
          parsedBody = s;
        }
      }
      final result = {
        'statusCode': resp.statusCode ?? 0,
        'headers': resp.headers.map.map(
          (k, v) => MapEntry(k, v.isNotEmpty ? v.first : ''),
        ),
        'body': parsedBody,
      };
      debugPrint('[LX] http ok ${resp.statusCode} $url');
      _resolveHttp(id, null, result);
    } catch (e) {
      debugPrint('[LX] http err $url -> $e');
      _resolveHttp(id, e.toString(), null);
    }
  }

  void _resolveHttp(dynamic id, String? err, Object? result) {
    final errJson = err == null ? 'null' : jsonEncode(err);
    final resJson = result == null ? 'null' : jsonEncode(result);
    try {
      _rt.evaluate('globalThis.__lxHttpResolve($id, $errJson, $resJson);');
      _drain();
      debugPrint('[LX] http resolve 回灌 id=$id err=${err != null}');
    } catch (e) {
      debugPrint('[LX] HTTP 回灌失败：$e');
    }
  }

  static Map<String, dynamic> _asMap(dynamic args) {
    if (args is Map) return args.map((k, v) => MapEntry(k.toString(), v));
    if (args is String) {
      try {
        final d = jsonDecode(args);
        if (d is Map) return d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}
    }
    return const {};
  }

  /// 洛雪的 `lx.currentScriptInfo`：从脚本头注释里取 @name / @description /
  /// @version / @author / @homepage，再附上脚本原文。
  static Map<String, String> scriptInfo(String script) {
    String tag(String name) =>
        RegExp(
          '@$name[ \\t]+([^\\r\\n*]+)',
        ).firstMatch(script)?.group(1)?.trim() ??
        '';
    return {
      'name': tag('name'),
      'description': tag('description'),
      'version': tag('version'),
      'author': tag('author'),
      'homepage': tag('homepage'),
      'rawScript': script,
    };
  }

  static String? parseName(String script) {
    final m = RegExp(r'@name\s+([^\r\n*]+)').firstMatch(script);
    return m?.group(1)?.trim();
  }

  /// 注入到 JS 的洛雪宿主垫片（单引擎只注一次）。每个脚本经 `__lxDefineScript`
  /// 拿到各自的 `lx`（handlers 独立），存入 `globalThis.__lxScripts[scriptId]`。
  /// HTTP 回调用全局自增 id、取址用全局 reqId 配对，跨脚本不串。
  static const String _hostShim = r'''
(function(){
  if (globalThis.__lxShimReady) return;
  globalThis.__lxShimReady = true;
  globalThis.__lxScripts = {};
  globalThis.__lxHttpCbs = {};
  globalThis.__lxHttpSeq = 0;
  var EVENT_NAMES = {
    request: 'request', inited: 'inited', updateAlert: 'updateAlert',
    updateMusicUrl: 'updateMusicUrl'
  };

  // ---- 洛雪 lx.utils 兼容层（2026-11-05）----
  // QuickJS / JavaScriptCore 没有 Node 的 Buffer / crypto，也没有 btoa / atob。
  // 以前 utils.crypto 是空对象、buffer 是假的，用到 md5 / base64 的脚本一调就崩。
  // 照洛雪移动版的接口补上（纯 JS）：buffer.from / bufToString（utf8、hex、
  // base64、binary）、crypto.md5 / randomBytes。aesEncrypt / rsaEncrypt / zlib
  // 太大没做，调用时给出明确的报错，测试结果里看得到原因。
  function utf8Encode(str){
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xdc00 && c2 < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00); i++; }
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }
  function utf8Decode(b){
    var s = '', i = 0;
    while (i < b.length) {
      var c = b[i++];
      if (c < 0x80) s += String.fromCharCode(c);
      else if (c < 0xe0) s += String.fromCharCode(((c & 31) << 6) | (b[i++] & 63));
      else if (c < 0xf0) { var x1 = b[i++] & 63, x2 = b[i++] & 63; s += String.fromCharCode(((c & 15) << 12) | (x1 << 6) | x2); }
      else {
        var y1 = b[i++] & 63, y2 = b[i++] & 63, y3 = b[i++] & 63;
        var cp = (((c & 7) << 18) | (y1 << 12) | (y2 << 6) | y3) - 0x10000;
        s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
      }
    }
    return s;
  }
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64Encode(b){
    var s = '', i = 0;
    for (; i + 2 < b.length; i += 3) {
      var n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
      s += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    var r = b.length - i;
    if (r === 1) { var n1 = b[i] << 16; s += B64[(n1 >> 18) & 63] + B64[(n1 >> 12) & 63] + '=='; }
    else if (r === 2) { var n2 = (b[i] << 16) | (b[i + 1] << 8); s += B64[(n2 >> 18) & 63] + B64[(n2 >> 12) & 63] + B64[(n2 >> 6) & 63] + '='; }
    return s;
  }
  function b64Decode(str){
    var t = String(str).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+\/]/g, '');
    var out = [], buf = 0, bits = 0;
    for (var i = 0; i < t.length; i++) {
      buf = ((buf << 6) | B64.indexOf(t.charAt(i))) & 0xffffff;
      bits += 6;
      if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 255); }
    }
    return out;
  }
  function hexEncode(b){
    var s = '';
    for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
    return s;
  }
  function hexDecode(str){
    var out = [];
    for (var i = 0; i + 1 < str.length; i += 2) out.push(parseInt(str.substr(i, 2), 16) & 255);
    return out;
  }
  function normEnc(enc){ return String(enc || 'utf8').toLowerCase().replace('-', ''); }
  function toBytes(v, enc){
    if (v == null) return [];
    if (typeof v === 'string') {
      var e = normEnc(enc);
      if (e === 'hex') return hexDecode(v);
      if (e === 'base64') return b64Decode(v);
      if (e === 'binary' || e === 'latin1' || e === 'ascii') {
        var a = [];
        for (var i = 0; i < v.length; i++) a.push(v.charCodeAt(i) & 255);
        return a;
      }
      return utf8Encode(v);
    }
    if (typeof v.length === 'number') {
      var o = [];
      for (var j = 0; j < v.length; j++) o.push(v[j] & 255);
      return o;
    }
    return utf8Encode(String(v));
  }
  function bufToString(b, enc){
    var bytes = toBytes(b), e = normEnc(enc);
    if (e === 'hex') return hexEncode(bytes);
    if (e === 'base64') return b64Encode(bytes);
    if (e === 'binary' || e === 'latin1' || e === 'ascii') {
      var s = '';
      for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
      return s;
    }
    return utf8Decode(bytes);
  }
  // 洛雪给的是 Node Buffer，脚本常写 buffer.from(x).toString('base64')
  function makeBuf(bytes){
    var u = new Uint8Array(bytes);
    u.toString = function(enc){ return bufToString(u, enc); };
    return u;
  }
  var MD5_K = [
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
    0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
    0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
    0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
    0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
    0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
  ];
  var MD5_S = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  function md5Hex(input){
    var msg = toBytes(input);
    var len = msg.length;
    msg.push(0x80);
    while (msg.length % 64 !== 56) msg.push(0);
    var lo = (len * 8) >>> 0, hi = Math.floor(len / 0x20000000) >>> 0;
    for (var k = 0; k < 4; k++) msg.push((lo >>> (8 * k)) & 255);
    for (var k2 = 0; k2 < 4; k2++) msg.push((hi >>> (8 * k2)) & 255);
    var a0 = 0x67452301, b0 = 0xefcdab89 | 0, c0 = 0x98badcfe | 0, d0 = 0x10325476;
    for (var off = 0; off < msg.length; off += 64) {
      var M = [];
      for (var w = 0; w < 16; w++) {
        var p = off + w * 4;
        M[w] = msg[p] | (msg[p + 1] << 8) | (msg[p + 2] << 16) | (msg[p + 3] << 24);
      }
      var A = a0, B = b0, C = c0, D = d0;
      for (var j = 0; j < 64; j++) {
        var F, g;
        if (j < 16) { F = (B & C) | (~B & D); g = j; }
        else if (j < 32) { F = (D & B) | (~D & C); g = (5 * j + 1) % 16; }
        else if (j < 48) { F = B ^ C ^ D; g = (3 * j + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * j) % 16; }
        F = (F + A + MD5_K[j] + M[g]) | 0;
        A = D; D = C; C = B;
        B = (B + ((F << MD5_S[j]) | (F >>> (32 - MD5_S[j])))) | 0;
      }
      a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
    }
    var out = '', words = [a0, b0, c0, d0];
    for (var q = 0; q < 4; q++) {
      for (var z = 0; z < 4; z++) {
        var x = (words[q] >>> (8 * z)) & 255;
        out += (x < 16 ? '0' : '') + x.toString(16);
      }
    }
    return out;
  }
  function unsupported(name){
    return function(){ throw new Error('App 暂不支持 lx.utils.' + name); };
  }
  var LX_UTILS = {
    buffer: {
      from: function(v, enc){ return makeBuf(toBytes(v, enc)); },
      bufToString: function(b, enc){ return bufToString(b, enc); }
    },
    crypto: {
      md5: function(v){ return md5Hex(v); },
      randomBytes: function(n){
        var a = [];
        for (var i = 0; i < n; i++) a.push(Math.floor(Math.random() * 256));
        return makeBuf(a);
      },
      aesEncrypt: unsupported('crypto.aesEncrypt'),
      rsaEncrypt: unsupported('crypto.rsaEncrypt')
    },
    zlib: {
      inflate: unsupported('zlib.inflate'),
      deflate: unsupported('zlib.deflate')
    }
  };
  globalThis.__lxUtils = LX_UTILS;
  if (typeof globalThis.btoa !== 'function') {
    globalThis.btoa = function(s){ return b64Encode(toBytes(String(s), 'binary')); };
  }
  if (typeof globalThis.atob !== 'function') {
    globalThis.atob = function(s){ return bufToString(b64Decode(s), 'binary'); };
  }
  function makeLx(scriptId, info){
    var handlers = {};
    var obj = {
      EVENT_NAMES: EVENT_NAMES,
      env: 'mobile',
      version: '2.0.0',
      // 洛雪会给脚本自己的元信息；有的脚本读 .version 做校验，没有就加载即崩
      currentScriptInfo: info || { name: '', description: '', version: '', author: '', homepage: '', rawScript: '' },
      on: function(name, fn){ handlers[name] = fn; },
      send: function(name, data){
        if (name === EVENT_NAMES.inited) {
          var sources = (data && data.sources) || {};
          try { sendMessage('lx_inited', JSON.stringify({ scriptId: scriptId, sources: sources })); } catch(e){}
        }
      },
      request: function(url, options, callback){
        var id = ++globalThis.__lxHttpSeq;
        globalThis.__lxHttpCbs[id] = callback || function(){};
        try { sendMessage('lx_http', JSON.stringify({ id: id, url: url, options: options || {} })); }
        catch(e){ var cb = globalThis.__lxHttpCbs[id]; delete globalThis.__lxHttpCbs[id]; cb(e, null); }
      },
      utils: LX_UTILS
    };
    globalThis.__lxScripts[scriptId] = { handlers: handlers, lx: obj };
    return obj;
  }
  globalThis.__lxDefineScript = function(scriptId, info, body){
    if (typeof info === 'function') { body = info; info = null; }
    var lx = makeLx(scriptId, info);
    // 既以参数传入，又设为全局：很多脚本从 globalThis.lx 解构取 request/on/
    // EVENT_NAMES 等。加载顺序执行、取址有串行闸，任一刻全局 lx 只属于当前脚本，
    // 隔离仍靠各自的 handlers，不会退回「只最后一个能用」。
    globalThis.lx = lx;
    try { body(lx); }
    catch(e){ try { sendMessage('lx_log', JSON.stringify({ msg: 'load err ' + scriptId + ': ' + e })); } catch(_){} }
  };
  globalThis.__lxUnload = function(scriptId){ try { delete globalThis.__lxScripts[scriptId]; } catch(e){} };
  globalThis.__lxHttpResolve = function(id, err, resp){
    var cb = globalThis.__lxHttpCbs[id];
    if (!cb) return;
    delete globalThis.__lxHttpCbs[id];
    // 洛雪的回调是 (err, resp, body)，有的脚本只读第三个参数
    try { cb(err, resp, resp ? resp.body : null); } catch(e){}
  };
  globalThis.__lxInvoke = function(scriptId, reqId, req){
    var s = globalThis.__lxScripts[scriptId];
    var h = (s && s.handlers) ? s.handlers[EVENT_NAMES.request] : null;
    if (!h) { sendMessage('lx_result', JSON.stringify({ reqId: reqId, err: 'no request handler' })); return; }
    // 处理器可能惰性引用 globalThis.lx，取址串行，调用前把全局指回本脚本。
    if (s.lx) globalThis.lx = s.lx;
    try {
      Promise.resolve(h(req)).then(function(res){
        var url = (res && res.url) ? res.url : (typeof res === 'string' ? res : '');
        sendMessage('lx_result', JSON.stringify({ reqId: reqId, url: url || '' }));
      }).catch(function(e){
        sendMessage('lx_result', JSON.stringify({ reqId: reqId, err: String(e) }));
      });
    } catch(e){
      sendMessage('lx_result', JSON.stringify({ reqId: reqId, err: String(e) }));
    }
  };
})();
''';
}

class _LxTask {
  _LxTask(this.run);
  final Future<String?> Function() run;
  final Completer<String?> result = Completer<String?>();

  /// 跑满超时才放弃（不含排队时间）。
  bool timedOut = false;

  /// 脚本自己 reject 的理由。
  String? error;
}
