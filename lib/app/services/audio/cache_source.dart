// ignore_for_file: experimental_member_use
// just_audio 的 StreamAudioSource/StreamAudioResponse 为实验性 API，
// 自研缓存源必须扩展它，此警告无法避免，文件级抑制。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

/// 自研音频流缓存源 —— 扩展 [StreamAudioSource]
///
/// 播放/预缓存时把远端音频流完整下载到本地文件，同时在下载过程中服务 just_audio
/// 的字节区间请求：
/// - **已缓存区域命中** → 直接从本地文件 [openRead] 秒播，不重新下载；
/// - 部分覆盖 → 本地已缓存部分 + 进行中下载流拼接；
/// - 超出当前已下载进度 → 另发上游 `Range:` 请求（服务器支持 206）。
///
/// 设计镜像 just_audio 内置 `LockCachingAudioSource`（just_audio.dart:3373-3689）的
/// 成熟下载循环，但接收具体缓存文件、暴露 [precache] 入口、以 [downloadDone] 报告完成，
/// 便于缓存管理服务做链式预缓存与上限淘汰。
///
/// 一个缓存文件只有一个下载循环（[StreamCacheService] 注册表保证每首歌共享同一实例）；
/// 循环由首次 [request] 或 [precache] 触发，期间所有并发字节请求由同一循环服务。
class StreamAudioCacheSource extends StreamAudioSource {
  final String songId;

  /// 流 URL（无 token 参数，cookie 认证）
  final Uri uri;

  /// 认证请求头（FeiNiuApiClient.imageAuthHeaders()）
  final Map<String, String> headers;

  /// 下载完成后的最终文件
  final File cacheFile;

  /// 下载中的临时文件（下载成功后被原子改名成 [cacheFile]）
  final File partFile;

  /// 记录原始 Content-Type 的旁路文件
  final File mimeFile;

  final List<_ByteRangeRequest> _requests = [];
  final List<_InProgressCacheResponse> _inProgressResponses = [];

  /// 下载完成信号。**不能是 final** —— 一次失败后它就永久带着那个错误，
  /// 后续重试即便成功也只会撞上 `isCompleted` 直接跳过，而 [precache] 里的
  /// `await _downloadCompleter.future` 会立刻重抛旧错误，表现成「重试了但还是
  /// 报同一个失败」。每次新的下载尝试都换一个新的 completer。
  Completer<void> _downloadCompleter = Completer<void>();

  Future<void>? _downloadFuture;
  int _progress = 0;
  int? _sourceLength;
  String _contentType = 'audio/mpeg';
  bool _downloading = false;
  bool _completed = false;

  /// 当前的 `.part` 是否由本实例在本次会话里写出来的。只有这样的残片才允许
  /// 续传 —— 详见 [_downloadToFile] 里的说明。
  bool _partFromThisSession = false;

  StreamAudioCacheSource({
    required this.songId,
    required this.uri,
    required this.headers,
    required this.cacheFile,
    super.tag,
  }) : partFile = File('${cacheFile.path}.part'),
       mimeFile = File('${cacheFile.path}.mime');

  bool get isDownloading => _downloading;
  bool get isComplete => _completed || cacheFile.existsSync();

  /// 下载完成信号（成功或失败都会完成；失败时 Future 带错误）
  Future<void> get downloadDone => _downloadCompleter.future;

  /// 触发下载并等待完成 —— 供预缓存调用。
  /// 若播放器已在下载同一首歌，则 join 同一循环；文件已完整则立即返回。
  Future<void> precache() async {
    if (isComplete) return;
    _ensureDownload();
    await _downloadCompleter.future;
  }

  void _ensureDownload() {
    if (_downloadFuture != null) return;
    // 上一轮失败后留下的是个已带错误的 completer，这一轮必须换新的，
    // 否则本轮的成功/失败都通知不出去（见字段上的说明）。
    if (_downloadCompleter.isCompleted) _downloadCompleter = Completer<void>();
    _downloadFuture = _runDownload();
  }

  Future<void> _runDownload() async {
    _downloading = true;
    try {
      await _downloadToFile();
    } catch (e, st) {
      // 下载失败：**保留** `.part` 供下次续传（弱网下这是关键 —— 一首 10MB 的歌
      // 下到 90% 断一下，以前整个删掉从 0 重来，现在下次带 Range 接着下）。
      // 安全性：下面紧接着 fail 掉所有在途请求、close 掉所有进行中的缓冲流，
      // 所以重试开始时**没有任何消费方正卡在流中间**，续传时把 _progress 重置
      // 成 `.part` 的真实字节数不会造成重复投喂。
      for (final req in _requests) {
        req.fail(e, st);
      }
      _requests.clear();
      // 失败路径同样关闭并清空进行中的下载缓冲流：这些控制器本应在下载
      // 完成时 close；失败不清理的话，消费方（just_audio）会一直等数据而
      // 不报错 → 悬挂且实例无法回收。主动 close 让消费方立即收到 EOF，
      // 由上层错误恢复机制（有重试上限）处理截断流。
      for (final r in _inProgressResponses) {
        if (!r.controller.isClosed) r.controller.close();
      }
      _inProgressResponses.clear();
      if (!_downloadCompleter.isCompleted) {
        _downloadCompleter.completeError(e, st);
      }
      _downloadFuture = null; // 允许后续重试
    } finally {
      _downloading = false;
    }
  }

  /// 单一顺序下载循环：完整 GET 流式写 `.part`，同时服务所有在途字节请求。
  Future<void> _downloadToFile() async {
    final client = _createHttpClient();
    // 下载句柄提升到外层作用域：无论成败都在 finally 里关闭，避免下载中途
    // 失败（网络抖动/服务器中断）时 IOSink 依赖 GC 兜底才释放 FD，长会话
    // 累积触发 macOS EMFILE「Too many open files」→ mpv 打开缓存文件失败
    // → 偶发播放失败（需重试多次才能成功）。
    IOSink? sink;
    try {
      // 续传起点 = `.part` 里已经落盘的字节数（上一轮失败时故意没删）。
      // 走到这里时在途请求都已被 fail、缓冲流都已 close，没有消费方卡在流中间，
      // 所以直接按文件真实长度对齐 _progress 是安全的。
      // ⚠️ 只续传**本次会话自己写出来的** `.part`。App 上次被杀时留下的残片
      // 无法保证和这次请求到的是同一份编码（服务端转码设置可能变过），接在
      // 后面会拼出一个坏文件，而且那种损坏只有播到后半段才暴露。旧代码每次
      // 都 truncate 所以不存在这问题，这里必须显式守住。
      var resumeFrom = 0;
      if (_partFromThisSession) {
        try {
          if (partFile.existsSync()) resumeFrom = partFile.lengthSync();
        } catch (_) {
          resumeFrom = 0;
        }
      }

      final httpRequest = await client.getUrl(uri);
      for (final entry in headers.entries) {
        httpRequest.headers.set(entry.key, entry.value);
      }
      if (resumeFrom > 0) {
        httpRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await httpRequest.close();

      // 206 = 服务器接受续传；200 = 它无视了 Range 要从头给（有些反代会这样），
      // 这时必须把 `.part` 截断重来，否则会把整首歌拼到已有字节后面，文件损坏。
      final resumed = resumeFrom > 0 && response.statusCode == 206;
      if (response.statusCode != 200 && !resumed) {
        throw Exception('HTTP Status Error: ${response.statusCode}');
      }

      partFile.createSync(recursive: true);
      if (resumed) {
        sink = partFile.openWrite(mode: FileMode.append);
        _progress = resumeFrom;
        // 206 的 contentLength 只是本段长度，总长要从 Content-Range 的 `/总数` 取；
        // 取不到就沿用上一轮已经拿到的 _sourceLength，别把它覆盖成错的。
        _sourceLength = _totalLengthFromContentRange(response) ?? _sourceLength;
      } else {
        sink = partFile.openWrite(); // 截断：从这一刻起这个 `.part` 归本实例所有
        _partFromThisSession = true;
        _progress = 0;
        _sourceLength = response.contentLength == -1
            ? null
            : response.contentLength;
      }
      _contentType = response.headers.contentType.toString();
      await mimeFile.writeAsString(_contentType);

      // 弱网失速检测：HttpClient 的 connectionTimeout 只管「连上」，连上之后
      // 服务器不发数据是不会超时的（半死的连接能挂很久）。Stream.timeout 在
      // 两个数据块之间超过阈值就抛错，让这一轮快点失败、把 `.part` 留给续传。
      await for (final data in response.timeout(_stallTimeout)) {
        _progress += data.length;
        sink.add(data);

        // 先把本次数据喂给已建立的进行中响应
        for (var cacheResponse in _inProgressResponses) {
          final end = cacheResponse.end;
          if (end != null && _progress >= end) {
            final subEnd = min(
              data.length,
              max(0, data.length - (_progress - end)),
            );
            cacheResponse.controller.add(data.sublist(0, subEnd));
            cacheResponse.controller.close();
          } else {
            cacheResponse.controller.add(data);
          }
        }
        _inProgressResponses.removeWhere(
          (element) => element.controller.isClosed,
        );

        if (_requests.isEmpty) continue;

        // 请求已覆盖范围前的数据必须已落盘，openRead 才能读到
        await sink.flush();

        final readyRequests = _requests
            .where((r) => r.start == null || r.start! < _progress)
            .toList();
        final notReadyRequests = _requests
            .where((r) => r.start != null && r.start! >= _progress)
            .toList();

        for (final request in readyRequests) {
          _requests.remove(request);
          final effectiveStart = request.start ?? 0;
          final effectiveEnd = request.end ?? _sourceLength;
          Stream<List<int>> responseStream;
          if (effectiveEnd != null && effectiveEnd <= _progress) {
            // 完全在已缓存区域 → 本地文件读取（秒播）
            responseStream = partFile.openRead(effectiveStart, effectiveEnd);
          } else {
            // 部分覆盖 → 已缓存部分 + 进行中下载流拼接
            final cacheResponse = _InProgressCacheResponse(end: effectiveEnd);
            _inProgressResponses.add(cacheResponse);
            responseStream = _concatStreams([
              partFile.openRead(effectiveStart, _progress),
              cacheResponse.controller.stream,
            ]);
          }
          request.complete(
            StreamAudioResponse(
              rangeRequestsSupported: true,
              // 同上：拿到了就报，不要因为是首次请求就藏起来。
              sourceLength: _sourceLength,
              contentLength: effectiveEnd != null
                  ? effectiveEnd - effectiveStart
                  : null,
              offset: request.start,
              contentType: _contentType,
              stream: responseStream.asBroadcastStream(),
            ),
          );
        }

        for (final request in notReadyRequests) {
          _requests.remove(request);
          final start = request.start!;
          final end = request.end ?? _sourceLength;
          unawaited(_issueRangeRequest(request, start, end));
        }
      }

      // 下载完成：关闭进行中响应、原子改名、报告完成
      for (var cacheResponse in _inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }
      _inProgressResponses.clear();
      await sink.close();
      sink = null;
      partFile.renameSync(cacheFile.path);
      _completed = true;
      if (!_downloadCompleter.isCompleted) {
        _downloadCompleter.complete();
      }
    } finally {
      // 无论成败都显式关闭文件句柄（幂等；成功路径已置 null 则跳过）。
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// 超出当前下载进度的区间请求：另发上游 `Range:` 请求（服务器支持 206）。
  Future<void> _issueRangeRequest(
    _ByteRangeRequest request,
    int start,
    int? end,
  ) async {
    final client = _createHttpClient();
    try {
      final httpRequest = await client.getUrl(uri);
      for (final entry in headers.entries) {
        httpRequest.headers.set(entry.key, entry.value);
      }
      httpRequest.headers.set(
        HttpHeaders.rangeHeader,
        end != null ? 'bytes=$start-${end - 1}' : 'bytes=$start-',
      );
      final response = await httpRequest.close();
      if (response.statusCode != 206) {
        throw Exception('HTTP Status Error: ${response.statusCode}');
      }
      request.complete(
        StreamAudioResponse(
          rangeRequestsSupported: true,
          sourceLength: _sourceLength,
          contentLength: end != null ? end - start : null,
          offset: start,
          contentType: _contentType,
          // 同样挂失速超时：这条流是直接交给 just_audio 消费的，服务器连上之后
          // 不发数据的话，不加超时就会无声无息地一直卡着（弱网常见）。
          stream: response.timeout(_stallTimeout).asBroadcastStream(),
        ),
      );
    } catch (e, st) {
      request.fail(e, st);
    } finally {
      client.close(force: true);
    }
  }

  /// 两个数据块之间最多等多久。超了就当这条连接废了，结束本轮、留 `.part` 续传。
  static const _stallTimeout = Duration(seconds: 20);

  /// 建连最多等多久。不设的话走 OS 默认（可能几十秒到几分钟），弱网下
  /// 表现成「点了播放长时间没反应也不报错」。
  static const _connectTimeout = Duration(seconds: 15);

  /// 从 `Content-Range: bytes 1000-9999/10000` 里取出总长度 `10000`。
  /// 拿不到（头缺失/格式不认识）返回 null，调用方沿用已知值。
  static int? _totalLengthFromContentRange(HttpClientResponse response) {
    final raw = response.headers.value(HttpHeaders.contentRangeHeader);
    if (raw == null) return null;
    final slash = raw.lastIndexOf('/');
    if (slash < 0 || slash + 1 >= raw.length) return null;
    final total = raw.substring(slash + 1).trim();
    if (total == '*') return null; // 服务器自己也不知道总长
    return int.tryParse(total);
  }

  HttpClient _createHttpClient() {
    // 继承 main.dart 的 HttpOverrides.global（SSL 忽略开关全局生效）
    final client = HttpClient();
    // 不自动解压，保证缓存字节与线上字节一致，sourceLength/contentLength 与文件相符
    client.autoUncompress = false;
    client.connectionTimeout = _connectTimeout;
    return client;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // 缓存文件已完整 → 直接从本地文件服务（秒播，无网络）
    if (cacheFile.existsSync()) {
      final length = cacheFile.lengthSync();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        // 总长已知就一定要报，哪怕这是首次（start == null）的整流请求。
        // 报 null 等于告诉播放器「长度未知」，它就没法做字节↔时间换算，
        // 只能按码率估算 —— VBR 文件估算必然偏，表现为拖动进度条后声音
        // 和进度对不上（歌词跟的是进度，于是看着像歌词不同步）。
        sourceLength: length,
        contentLength: (end ?? length) - (start ?? 0),
        offset: start,
        contentType: _readCachedMime(),
        stream: cacheFile.openRead(start, end).asBroadcastStream(),
      );
    }

    final req = _ByteRangeRequest(start, end);
    _requests.add(req);
    _ensureDownload();
    final resp = await req.future;
    // 保持一个监听者使广播流保持活跃；流出错时 fail 在途请求避免悬挂
    resp.stream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        for (final r in _requests) {
          r.fail(e, st);
        }
      },
    );
    return resp;
  }

  String _readCachedMime() {
    try {
      if (mimeFile.existsSync()) return mimeFile.readAsStringSync();
    } catch (_) {}
    return 'audio/mpeg';
  }

  /// 本地实现 `Rx.concatEager` 语义（避免引入 rxdart 依赖）
  static Stream<List<int>> _concatStreams(
    List<Stream<List<int>>> streams,
  ) async* {
    for (final stream in streams) {
      yield* stream;
    }
  }
}

/// 一次字节区间请求（completer + fail 防重）
class _ByteRangeRequest {
  final int? start;
  final int? end;
  final Completer<StreamAudioResponse> completer =
      Completer<StreamAudioResponse>();

  _ByteRangeRequest(this.start, this.end);

  Future<StreamAudioResponse> get future => completer.future;

  void complete(StreamAudioResponse response) {
    if (!completer.isCompleted) completer.complete(response);
  }

  void fail(Object error, StackTrace? stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }
}

/// 部分覆盖请求的进行中下载缓冲（缓存读到 [_InProgressCacheResponse.end] 为止）
class _InProgressCacheResponse {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  final int? end;

  _InProgressCacheResponse({this.end});
}
