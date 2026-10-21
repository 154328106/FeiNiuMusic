import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

/// 单个 LX（洛雪）脚本音源的运行时。
///
/// 在应用内 JS 引擎（iOS=JavaScriptCore / Android=QuickJS，由 flutter_js 适配）
/// 里注入洛雪约定的 `globalThis.lx` 宿主对象，加载用户脚本，暴露：
/// - [sources]：脚本声明支持的平台代号（wy/tx/kg/kw/mg…）与音质；
/// - [getMusicUrl]：按 `{source, songId, quality}` 调脚本注册的 request 处理器取直链。
///
/// 桥接：JS 的异步 HTTP（`lx.request`）与取址处理器（返回 Promise）都走
/// 「sendMessage 出来 → Dart 干活 → evaluate 把结果灌回 JS」这一套，靠
/// reqId 配对，避免依赖具体引擎的 Promise 返回值语义。
class LxScriptRuntime {
  LxScriptRuntime();

  final JavascriptRuntime _rt = getJavascriptRuntime();
  final Dio _dio = Dio(
    BaseOptions(
      // 脚本自己判断状态码；重定向默认跟随，脚本可用 options 关掉。
      validateStatus: (_) => true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  int _reqSeq = 0;
  final Map<int, Completer<String?>> _invokeWaiters = {};
  final Completer<void> _initedWaiter = Completer<void>();
  Timer? _pump;
  bool _disposed = false;

  /// 脚本 send(inited) 声明的支持平台代号（如 wy/tx/kg/kw/mg）。
  List<String> sources = const [];

  /// 脚本名（从 @name 注释尽力解析，仅展示用）。
  String name = '';

  /// 加载脚本文本并等待其 `send(EVENT_NAMES.inited)`。返回是否成功 inited。
  Future<bool> load(String scriptText, {Duration? timeout}) async {
    try {
      name = _parseName(scriptText) ?? name;
      _registerChannels();
      _rt.evaluate(_hostShim);
      _rt.evaluate(scriptText);
      _startPump();
      await _initedWaiter.future.timeout(timeout ?? const Duration(seconds: 8));
      return true;
    } catch (e) {
      debugPrint('[LX] 脚本加载失败：$e');
      return false;
    }
  }

  /// 调脚本取某首歌的可播放直链。[info] 是传给脚本的歌曲信息（songmid/hash 等）。
  Future<String?> getMusicUrl({
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
  }) async {
    if (_disposed) return null;
    final reqId = ++_reqSeq;
    final completer = Completer<String?>();
    _invokeWaiters[reqId] = completer;
    // 关键：重启微任务泵。加载完成后 _pump 会自行取消（见 _startPump），
    // 而 QuickJS（Android）的 Promise 链全靠它驱动——不重启，HTTP 回调后的
    // .then 永不执行，整条取址 Promise 卡死到超时。iOS 的 JSCore 有原生事件
    // 循环不受影响，所以当初只在 Android 上表现为「Future not completed」。
    _startPump();
    // 洛雪(LX)约定：musicUrl 请求的 info 是 { type: 音质, musicInfo: {歌曲对象} }，
    // 脚本按 info.musicInfo / info.type 取（见 ikun 等脚本的 on(request) 实现）。
    // 之前把歌曲字段平铺在 info 里，脚本读 info.musicInfo 取到 undefined → 请求发空
    // id → 后端一律「无货」。
    final payload = jsonEncode({
      'action': 'musicUrl',
      'source': source,
      'info': {'type': quality, 'musicInfo': info},
    });
    try {
      debugPrint('[LX] invoke reqId=$reqId source=$source');
      _rt.evaluate('globalThis.__lxInvoke($reqId, $payload);');
      _drain();
      return await completer.future.timeout(
        timeout ?? const Duration(seconds: 20),
      );
    } catch (e) {
      debugPrint('[LX] getMusicUrl 失败：$e');
      return null;
    } finally {
      _invokeWaiters.remove(reqId);
    }
  }

  void dispose() {
    _disposed = true;
    _pump?.cancel();
    try {
      _rt.dispose();
    } catch (_) {}
    for (final c in _invokeWaiters.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _invokeWaiters.clear();
  }

  // ---- 内部 ----

  /// 周期性泵 QuickJS 的 Promise/microtask 任务队列（JSCore 由系统泵，调用
  /// 它无害）。只在有未完成的取址等待或刚加载时需要。
  void _startPump() {
    _pump ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_disposed) return;
      _drain();
      if (_invokeWaiters.isEmpty && _initedWaiter.isCompleted) {
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
    // 取址处理器的结果（Promise resolve/reject 后脚本发回来）。
    _rt.onMessage('lx_result', (dynamic args) {
      final map = _asMap(args);
      final id = map['reqId'];
      debugPrint(
        '[LX] lx_result reqId=$id url?=${(map['url'] ?? '').toString().isNotEmpty} err=${map['err']}',
      );
      final waiter = id is int ? _invokeWaiters[id] : null;
      if (waiter != null && !waiter.isCompleted) {
        final url = map['url'];
        waiter.complete(url is String && url.isNotEmpty ? url : null);
      }
      return null;
    });
    // 脚本声明支持的源。
    _rt.onMessage('lx_inited', (dynamic args) {
      final map = _asMap(args);
      final list = map['sources'];
      if (list is Map) {
        sources = list.keys.map((e) => e.toString()).toList();
      } else if (list is List) {
        sources = list.map((e) => e.toString()).toList();
      }
      if (!_initedWaiter.isCompleted) _initedWaiter.complete();
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
    if (_disposed) return;
    try {
      final method = (options['method'] ?? 'GET').toString().toUpperCase();
      final headers = <String, dynamic>{};
      final rawHeaders = options['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) => headers[k.toString()] = v);
      }
      dynamic body = options['body'] ?? options['form'] ?? options['data'];
      debugPrint('[LX] http $method $url');
      // form 对象按表单编码；其余按原样（字符串/JSON）交给 dio。
      final resp = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          followRedirects: options['follow_max'] != 0,
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
    if (_disposed) return;
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

  static String? _parseName(String script) {
    final m = RegExp(r'@name\s+([^\r\n*]+)').firstMatch(script);
    return m?.group(1)?.trim();
  }

  /// 注入到 JS 的洛雪宿主垫片。只实现 url 类脚本必需的面：
  /// request / on / send / EVENT_NAMES / env / version，外加一个轻量 utils。
  static const String _hostShim = r'''
(function(){
  if (globalThis.__lxShimReady) return;
  globalThis.__lxShimReady = true;
  globalThis.__lxHttpCbs = {};
  globalThis.__lxHttpSeq = 0;
  var EVENT_NAMES = {
    request: 'request', inited: 'inited', updateAlert: 'updateAlert',
    updateMusicUrl: 'updateMusicUrl'
  };
  var handlers = {};
  globalThis.lx = {
    EVENT_NAMES: EVENT_NAMES,
    env: 'mobile',
    version: '2.0.0',
    on: function(name, fn){ handlers[name] = fn; },
    send: function(name, data){
      if (name === EVENT_NAMES.inited) {
        var sources = (data && data.sources) || {};
        try { sendMessage('lx_inited', JSON.stringify({ sources: sources })); } catch(e){}
      }
    },
    request: function(url, options, callback){
      var id = ++globalThis.__lxHttpSeq;
      globalThis.__lxHttpCbs[id] = callback || function(){};
      try { sendMessage('lx_http', JSON.stringify({ id: id, url: url, options: options || {} })); }
      catch(e){ var cb = globalThis.__lxHttpCbs[id]; delete globalThis.__lxHttpCbs[id]; cb(e, null); }
    },
    utils: {
      buffer: {
        from: function(v, enc){ return { __raw: v, enc: enc || 'utf8' }; },
        bufToString: function(b, enc){ return (b && b.__raw != null) ? String(b.__raw) : String(b); }
      },
      crypto: {}
    }
  };
  globalThis.__lxHttpResolve = function(id, err, resp){
    var cb = globalThis.__lxHttpCbs[id];
    if (!cb) return;
    delete globalThis.__lxHttpCbs[id];
    try { cb(err, resp); } catch(e){}
  };
  globalThis.__lxInvoke = function(reqId, req){
    var h = handlers[EVENT_NAMES.request];
    if (!h) { sendMessage('lx_result', JSON.stringify({ reqId: reqId, err: 'no request handler' })); return; }
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
