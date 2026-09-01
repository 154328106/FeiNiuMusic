import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

  /// 超过这个时间就当取不到色。
  ///
  /// 这道闸不能省：之前用 Dio 自己下图，请求挂住后 `_inflight` 里那个
  /// Future 永远悬着，之后每次取色都在 await 同一个死掉的 Future ——
  /// 线上表现是「一次都不成功，而且一条日志都不打」。
  static const Duration _timeout = Duration(seconds: 8);

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

  /// 把封面解码成一张 [ui.Image]。
  ///
  /// 走的是**界面显示封面用的同一个 ImageProvider** —— 那条路已经被验证是
  /// 通的（图能显示出来），而且图早就下好躺在缓存里，不会再发一次请求。
  /// 之前自己拿 Dio 重下一遍，在 iOS 上会毫无征兆地悬住，连超时都不触发。
  static Future<ui.Image> _decode(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  static Future<Color?> _compute(String coverId) async {
    final isRemote = coverId.startsWith('http');
    // 用**显示时那个地址**去取，才能命中已经下好的缓存。飞牛按 size 拼，
    // 网易云的 coverId 本身就是完整直链。
    final url = isRemote
        ? coverId
        : FeiNiuApiClient.instance.coverUrl(
            coverId,
            size: FeiNiuApiClient.coverRequestSize,
          );
    debugPrint('[CoverColor] 开始取色 $url');
    try {
      final image = await _decode(
        CachedNetworkImageProvider(
          url,
          // 公网直链不能带飞牛的鉴权头（与 ArtworkWidget 同一套判断）。
          headers: isRemote ? null : FeiNiuApiClient.imageAuthHeaders(),
        ),
      ).timeout(_timeout);
      final color = await _averageOf(image);
      image.dispose();
      if (color == null) {
        debugPrint('[CoverColor] 解码成功但算不出颜色 $url');
        return null;
      }
      if (_cache.length >= _cacheLimit) {
        // 插入有序：淘汰最早的一条，别让缓存无限涨。
        _cache.remove(_cache.keys.first);
      }
      _cache[coverId] = color;
      return color;
    } catch (e) {
      debugPrint('[CoverColor] 取色失败 $url：$e');
      return null;
    }
  }

  /// 对一张已解码的图求平均色。
  ///
  /// 封面是原尺寸的（几百到上千像素），全像素遍历没必要，按步长抽样即可 ——
  /// 平均色本来就不需要精确。
  static Future<Color?> _averageOf(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final bytes = data.buffer.asUint8List();
    // 目标是取够约 4096 个采样点。
    final pixels = bytes.length ~/ 4;
    final step = pixels <= 4096 ? 1 : pixels ~/ 4096;
    var r = 0;
    var g = 0;
    var b = 0;
    var count = 0;
    for (var i = 0; i < pixels; i += step) {
      final o = i * 4;
      if (bytes[o + 3] < 10) continue; // 透明像素不参与
      r += bytes[o];
      g += bytes[o + 1];
      b += bytes[o + 2];
      count++;
    }
    if (count == 0) return null;
    return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
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
