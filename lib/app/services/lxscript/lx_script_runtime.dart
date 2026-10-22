import 'dart:async';
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

  /// 脚本 send(inited) 声明的支持平台代号（如 wy/tx/kg/kw/mg）。
  List<String> get sources => _LxEngine.instance.sourcesOf(_scriptId);

  /// 加载脚本文本并等待其 `send(EVENT_NAMES.inited)`。返回是否成功 inited。
  Future<bool> load(String scriptText, {Duration? timeout}) {
    name = _LxEngine.parseName(scriptText) ?? name;
    return _LxEngine.instance.loadScript(_scriptId, scriptText, timeout: timeout);
  }

  /// 调脚本取某首歌的可播放直链。[info] 是传给脚本的歌曲信息（songmid/hash 等）。
  Future<String?> getMusicUrl({
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
  }) => _LxEngine.instance.getUrl(
    _scriptId,
    source: source,
    info: info,
    quality: quality,
    timeout: timeout,
  );

  void dispose() => _LxEngine.instance.unloadScript(_scriptId);
}

/// 全应用唯一的 LX JS 引擎。持有唯一的 [JavascriptRuntime]，所有脚本在同一个
/// JS 上下文里按 scriptId 分隔（`globalThis.__lxScripts[scriptId]`）。
///
/// 取址全局串行（[_gate]）：JS 引擎单线程驱动，一次只跑一个取址，避免 evaluate /
/// 微任务泵交叠。HTTP 回调与取址结果用全局自增 id 配对，和 scriptId 无关。
class _LxEngine {
  _LxEngine._();
  static final _LxEngine instance = _LxEngine._();

  final JavascriptRuntime _rt = getJavascriptRuntime();
  final Dio _dio = Dio(
    BaseOptions(
      // 脚本自己判断状态码；重定向默认跟随，脚本可用 options 关掉。
      validateStatus: (_) => true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  bool _booted = false;
  int _reqSeq = 0;
  Timer? _pump;

  /// 取址串行闸。
  Future<void> _gate = Future<void>.value();

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
          'globalThis.__lxDefineScript(${jsonEncode(scriptId)}, function(lx){\n'
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

  /// 取某脚本的直链。排到 [_gate] 尾部，前一个取址彻底结束后再碰引擎。
  Future<String?> getUrl(
    String scriptId, {
    required String source,
    required Map<String, dynamic> info,
    required String quality,
    Duration? timeout,
  }) {
    final prev = _gate;
    final gate = Completer<void>();
    _gate = gate.future;
    return prev.then((_) {
      return _getUrlLocked(
        scriptId,
        source: source,
        info: info,
        quality: quality,
        timeout: timeout,
      );
    }).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
    });
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
  function makeLx(scriptId){
    var handlers = {};
    globalThis.__lxScripts[scriptId] = { handlers: handlers };
    return {
      EVENT_NAMES: EVENT_NAMES,
      env: 'mobile',
      version: '2.0.0',
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
      utils: {
        buffer: {
          from: function(v, enc){ return { __raw: v, enc: enc || 'utf8' }; },
          bufToString: function(b, enc){ return (b && b.__raw != null) ? String(b.__raw) : String(b); }
        },
        crypto: {}
      }
    };
  }
  globalThis.__lxDefineScript = function(scriptId, body){
    var lx = makeLx(scriptId);
    try { body(lx); }
    catch(e){ try { sendMessage('lx_log', JSON.stringify({ msg: 'load err ' + scriptId + ': ' + e })); } catch(_){} }
  };
  globalThis.__lxUnload = function(scriptId){ try { delete globalThis.__lxScripts[scriptId]; } catch(e){} };
  globalThis.__lxHttpResolve = function(id, err, resp){
    var cb = globalThis.__lxHttpCbs[id];
    if (!cb) return;
    delete globalThis.__lxHttpCbs[id];
    try { cb(err, resp); } catch(e){}
  };
  globalThis.__lxInvoke = function(scriptId, reqId, req){
    var s = globalThis.__lxScripts[scriptId];
    var h = (s && s.handlers) ? s.handlers[EVENT_NAMES.request] : null;
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
