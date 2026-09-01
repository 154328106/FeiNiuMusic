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

  /// 每算出一张封面的主色就自增。
  ///
  /// UI 监听它、再同步读 [cached]，就不用在 widget 里持有 Future。上一版用
  /// FutureBuilder，线上出现过「同一个 coverId 的取色已经成功、snapshot 却
  /// 永远停在 waiting」，那条通知链不可靠，索性绕开。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 已经算过就同步给出，省掉一帧空窗。
  static Color? cached(String coverId) => _cache[coverId];

  static Future<Color?> resolve(String coverId) {
    if (coverId.isEmpty) return Future<Color?>.value();
    final hit = _cache[coverId];
    if (hit != null) return Future<Color?>.value(hit);
    // 超时挡在最外层。里面任何一步卡住都能兜住并留下日志 —— 之前把超时挂在
    // 单个 await 上，卡在别处时整个 Future 悬着，连一行日志都不打。
    return _inflight[coverId] ??= _compute(coverId)
        .timeout(
          _timeout,
          onTimeout: () {
            debugPrint('[CoverColor] 取色超时 $coverId');
            return null;
          },
        )
        .whenComplete(() => _inflight.remove(coverId));
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
      // 交给 SDK 自带的 ColorScheme.fromImageProvider —— 它内部会把图缩到
      // 112px 再做 Celebi 量化，拿到的是「这张图的主色」而不是平均出来的
      // 一坨灰。自己下图 + 求平均那两版在 iOS 上都会莫名悬住，而这条是
      // Flutter 维护的路径。
      final scheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(
          url,
          // 公网直链不能带飞牛的鉴权头（与 ArtworkWidget 同一套判断）。
          headers: isRemote ? null : FeiNiuApiClient.imageAuthHeaders(),
        ),
      );
      final color = scheme.primary;
      if (_cache.length >= _cacheLimit) {
        // 插入有序：淘汰最早的一条，别让缓存无限涨。
        _cache.remove(_cache.keys.first);
      }
      _cache[coverId] = color;
      revision.value++;
      // Color.toString() 在 release 下只给 "Instance of 'Color'"，
      // 打十六进制才看得出取到的是什么颜色。
      debugPrint(
        '[CoverColor] 取色成功 #'
        '${color.toARGB32().toRadixString(16).padLeft(8, '0')}',
      );
      return color;
    } catch (e) {
      debugPrint('[CoverColor] 取色失败 $url：$e');
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
