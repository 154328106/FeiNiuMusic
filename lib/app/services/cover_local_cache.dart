import 'dart:io' as io;

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'feiniu/api_client.dart';

/// 封面本地缓存共享工具：切歌悬浮窗、灵动岛等原生覆盖层共用。
///
/// 三步策略：
/// 1. 查 flutter_cache_manager（CachedNetworkImage 共用）已有磁盘缓存；
/// 2. 无缓存时经 getSingleFile 下载到缓存池（带认证头）；
/// 3. fallback 下载到独立目录（自签名证书兼容），路径可在原生层直接读。
class CoverLocalCache {
  CoverLocalCache._();

  static const String kDirName = 'covers_v2';

  static final DefaultCacheManager _coverCache = DefaultCacheManager();

  static String? _dirPath;

  static Future<String> coverDirPath() async {
    if (_dirPath == null) {
      final dir = await getTemporaryDirectory();
      _dirPath = '${dir.path}/$kDirName';
      await io.Directory(_dirPath!).create(recursive: true);
    }
    return _dirPath!;
  }

  static Future<String?> downloadToLocal(String coverId, {int? updatedAt}) async {
    final url = FeiNiuApiClient.instance.coverUrl(
      coverId, size: 120, updatedAt: updatedAt,
    );
    try {
      final cacheObject = await _coverCache.getFileFromCache(url);
      if (cacheObject != null) {
        final f = io.File(cacheObject.file.path);
        if (await f.exists()) return f.path;
      }
    } catch (_) {}
    try {
      final cacheFile = await _coverCache.getSingleFile(
        url,
        headers: FeiNiuApiClient.imageAuthHeaders(),
      );
      final f = io.File(cacheFile.path);
      if (await f.exists()) return f.path;
    } catch (_) {}
    try {
      final dir = await coverDirPath();
      final suffix = (updatedAt != null && updatedAt > 0) ? '_$updatedAt' : '';
      final filePath = '$dir/${coverId}_120$suffix.jpg';
      final file = io.File(filePath);
      if (await file.exists()) return filePath;
      final httpClient = io.HttpClient()..badCertificateCallback = (_, _, _) => true;
      try {
        final request = await httpClient.getUrl(Uri.parse(url));
        if (FeiNiuApiClient.instance.token.isNotEmpty) {
          final headers = FeiNiuApiClient.instance.authHeaders();
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          await file.writeAsBytes(bytes);
          return filePath;
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (_) {}
    return null;
  }
}
