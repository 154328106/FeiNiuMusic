import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'feiniu/api_client.dart';

/// 封面本地缓存共享工具：切歌悬浮窗、灵动岛等原生覆盖层共用。
///
/// 三步策略：
/// 1. 查 flutter_cache_manager（CachedNetworkImage 共用）已有磁盘缓存；
/// 2. 无缓存时经 getSingleFile 下载到缓存池（带认证头）；
/// 3. fallback 下载到独立目录（自签名证书兼容），供原生层和车机封面
///    Provider 读取。
class CoverLocalCache {
  CoverLocalCache._();

  static const String kDirName = 'covers_v2';

  static final DefaultCacheManager _coverCache = DefaultCacheManager();

  static String? _dirPath;
  static Future<String>? _applicationId;

  static Future<String> coverDirPath() async {
    if (_dirPath == null) {
      final dir = await getTemporaryDirectory();
      _dirPath = '${dir.path}/$kDirName';
      await io.Directory(_dirPath!).create(recursive: true);
    }
    return _dirPath!;
  }

  /// Returns a URI that Android Auto and other external media clients can
  /// safely read. The provider only exposes files produced by this cache.
  static Future<Uri?> contentUriForPath(String? localPath) async {
    if (localPath == null || localPath.isEmpty) return null;
    final fileName = path.basename(localPath);
    if (!RegExp(r'^[0-9a-f]{40}\.img$').hasMatch(fileName)) return null;
    final applicationId = await _resolveApplicationId();
    return Uri(
      scheme: 'content',
      host: '$applicationId.coverart',
      pathSegments: <String>[fileName],
    );
  }

  static Future<String?> downloadToLocal(
    String coverId, {
    int? updatedAt,
  }) async {
    final target = await _cacheFileFor(coverId, updatedAt: updatedAt);
    if (await target.exists()) return target.path;

    final url = FeiNiuApiClient.instance.coverUrl(
      coverId,
      size: 120,
      updatedAt: updatedAt,
    );
    try {
      final cacheObject = await _coverCache.getFileFromCache(url);
      if (cacheObject != null) {
        final f = io.File(cacheObject.file.path);
        if (await f.exists()) return _copyToCoverCache(f, target);
      }
    } catch (error) {
      _debugLog('read cached cover failed: $error');
    }
    try {
      final cacheFile = await _coverCache.getSingleFile(
        url,
        headers: FeiNiuApiClient.imageAuthHeaders(),
      );
      final f = io.File(cacheFile.path);
      if (await f.exists()) return _copyToCoverCache(f, target);
    } catch (error) {
      _debugLog('download cover with cache manager failed: $error');
    }
    try {
      final httpClient = io.HttpClient()
        ..badCertificateCallback = (_, _, _) => true;
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
          await target.writeAsBytes(bytes, flush: true);
          return target.path;
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (error) {
      _debugLog('download cover fallback failed: $error');
    }
    return null;
  }

  static Future<io.File> _cacheFileFor(String coverId, {int? updatedAt}) async {
    final cacheKey = '$coverId:${updatedAt ?? 0}';
    final fileName = '${sha1.convert(utf8.encode(cacheKey))}.img';
    return io.File('${await coverDirPath()}/$fileName');
  }

  static Future<String?> _copyToCoverCache(
    io.File source,
    io.File target,
  ) async {
    try {
      if (!await target.exists()) {
        await source.copy(target.path);
      }
      return target.path;
    } catch (error) {
      _debugLog('copy cover into shared cache failed: $error');
      return null;
    }
  }

  static void _debugLog(String message) {
    debugPrint('[CoverLocalCache] $message');
  }

  static Future<String> _resolveApplicationId() {
    return _applicationId ??= _loadApplicationId();
  }

  static Future<String> _loadApplicationId() async {
    try {
      return (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {
      return 'com.feiniu.music';
    }
  }
}
