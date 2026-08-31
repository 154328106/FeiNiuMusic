import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
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

  static Future<Color?> _compute(String coverId) async {
    try {
      final isRemote = coverId.startsWith('http');
      // 取色只要几十像素的缩略图。飞牛按 size 参数要小图；网易云图床支持
      // `?param=WxH`，不加的话会把整张大图拖下来只为算个平均色。
      final url = isRemote
          ? (coverId.contains('?') ? coverId : '$coverId?param=64y64')
          : FeiNiuApiClient.instance.coverUrl(coverId, size: 40);
      final response = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: isRemote ? null : FeiNiuApiClient.instance.authHeaders(),
        ),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      final color = await averageImageColor(Uint8List.fromList(data));
      if (color == null) return null;
      if (_cache.length >= _cacheLimit) {
        // 插入有序：淘汰最早的一条，别让缓存无限涨。
        _cache.remove(_cache.keys.first);
      }
      _cache[coverId] = color;
      return color;
    } catch (_) {
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
