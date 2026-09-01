import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/feiniu/api_client.dart';

/// 封面主色调的共享取色器。
///
/// 播放页背景一直在做这件事，但那份实现把地址写死成飞牛的 `/static/cover`
/// —— 网易云的 coverId 本身就是公网直链，套进去会拼出 NAS 一律 400 的地址，
/// 取色直接失败。这里把「按来源分流 + 缓存 + 并发合并」抽出来共用。
class CoverDominantColor {
  CoverDominantColor._();

  static const int _cacheLimit = 128;
  static final Map<String, Color> _cache = {};
  static final Map<String, Future<Color?>> _inflight = {};

  /// 取一张缩略图算平均色，超过这个时间就当没有。
  ///
  /// 原来这里是裸 `Dio()`，没配任何超时。请求一挂住，`_inflight` 里那个
  /// Future 就永远悬着，之后每次取色都在 await 同一个死掉的 Future ——
  /// 表现是「取色一次都不成功，而且一条日志都不打」。
  static const Duration _timeout = Duration(seconds: 6);

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      responseType: ResponseType.bytes,
      // 图床偶尔 302 到别的域名，跟过去就好。
      followRedirects: true,
    ),
  );

  /// 已经算过就同步给出，省掉一帧空窗。
  static Color? cached(String coverId) => _cache[coverId];

  static Future<Color?> resolve(String coverId) {
    if (coverId.isEmpty) return Future<Color?>.value();
    final hit = _cache[coverId];
    if (hit != null) return Future<Color?>.value(hit);
    return _inflight[coverId] ??= _compute(
      coverId,
    ).whenComplete(() => _inflight.remove(coverId));
  }

  /// 先看磁盘缓存里有没有这张封面。
  ///
  /// 列表和大图早就用 CachedNetworkImage 把它下下来了，和这里共用同一个
  /// DefaultCacheManager。直接读文件既省一次网络往返，也绕开了「网络那条
  /// 路不通就永远取不到色」。
  static Future<Uint8List?> _fromImageCache(String url) async {
    try {
      final info = await DefaultCacheManager().getFileFromCache(url);
      final file = info?.file;
      if (file == null || !await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<Color?> _compute(String coverId) async {
    try {
      final isRemote = coverId.startsWith('http');
      // 取色只要几十像素的缩略图。飞牛按 size 参数要小图；网易云图床支持
      // `?param=WxH`，不加的话会把整张大图拖下来只为算个平均色。
      //
      // 网易云给的地址是 http 的，这里统一升到 https：iOS 默认禁明文，
      // 走 http 要么被拦要么干脆挂住不返回。
      var url = isRemote
          ? (coverId.contains('?') ? coverId : '$coverId?param=64y64')
          : FeiNiuApiClient.instance.coverUrl(coverId, size: 40);
      if (url.startsWith('http://')) {
        url = url.replaceFirst('http://', 'https://');
      }
      // 先吃缓存：界面上已经显示过这张封面，文件多半就在本地。
      // 缓存键是**显示用的那个地址**，不是上面拼出来的缩略图地址。
      final displayUrl = isRemote
          ? coverId
          : FeiNiuApiClient.instance.coverUrl(
              coverId,
              size: FeiNiuApiClient.coverRequestSize,
            );
      var bytes = await _fromImageCache(displayUrl);
      if (bytes == null && displayUrl != url) {
        bytes = await _fromImageCache(url);
      }

      if (bytes == null) {
        final response = await _dio
            .get<List<int>>(
              url,
              options: Options(
                responseType: ResponseType.bytes,
                headers: isRemote
                    ? null
                    : FeiNiuApiClient.instance.authHeaders(),
              ),
            )
            // 双保险：就算 Dio 的超时没兜住，也不能让这个 Future 永远不返回。
            .timeout(_timeout);
        final data = response.data;
        if (data == null || data.isEmpty) {
          debugPrint('[CoverColor] 空响应 $url');
          return null;
        }
        bytes = Uint8List.fromList(data);
      }

      final color = await averageImageColor(bytes);
      if (color == null) return null;
      if (_cache.length >= _cacheLimit) {
        // 插入有序：淘汰最早的一条，别让缓存无限涨。
        _cache.remove(_cache.keys.first);
      }
      _cache[coverId] = color;
      return color;
    } catch (e) {
      debugPrint('[CoverColor] 取色失败 $coverId：$e');
      return null;
    }
  }
}

/// 解码 [bytes] 并求平均色（先降采样再平均，够快也够稳）。
///
/// 播放页背景、流光预览、首页漫游卡都用它。
Future<Color?> averageImageColor(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: 40,
    targetHeight: 40,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final list = data.buffer.asUint8List();
  int r = 0;
  int g = 0;
  int b = 0;
  int count = 0;
  for (var i = 0; i + 3 < list.length; i += 4) {
    final a = list[i + 3];
    if (a < 10) continue;
    r += list[i];
    g += list[i + 1];
    b += list[i + 2];
    count += 1;
  }
  if (count == 0) return null;
  return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
}
