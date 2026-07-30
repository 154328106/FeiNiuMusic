import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage>
    with SignalsMixin {
  late final _artworkCacheSize = createSignal(0);
  late final _lyricsCacheSize = createSignal(0);
  late final _loading = createSignal(true);

  @override
  void initState() {
    super.initState();
    AppCacheSettings.ensureLoaded();
    _loadCacheSizes();
  }

  Future<void> _loadCacheSizes() async {
    _loading.value = true;
    final artworkSize = await _getArtworkCacheSize();
    final lyricsSize = await _getLyricsCacheSize();
    if (!mounted) return;
    _artworkCacheSize.value = artworkSize;
    _lyricsCacheSize.value = lyricsSize;
    _loading.value = false;
  }

  Future<int> _getArtworkCacheSize() async {
    // CachedNetworkImage + flutter_cache_manager stores cache under
    // getTemporaryDirectory()/<db file dir>/ - on Android it's
    // context.getCacheDir()/cached_network_image/
    // Try multiple possible locations
    try {
      final tempDir = await getTemporaryDirectory();
      // flutter_cache_manager v3 stores cache in a subdirectory
      // of getTemporaryDirectory() named after the db file
      final cacheDir = Directory(p.join(tempDir.path, 'cached_network_image'));
      int size = await _dirSize(cacheDir);
      if (size > 0) return size;
      // Try alternative: flutter_cache_manager stores in
      // getTemporaryDirectory()/.cache/ or just the temp dir root
      final altDir = Directory(tempDir.path);
      // Look for cache files
      try {
        await for (final f in altDir.list(recursive: true, followLinks: false)) {
          if (f is File && p.extension(f.path) == '.jpg') {
            size += await f.length();
          }
        }
      } catch (_) {}
      if (size > 0) return size;
      // Check application support directory
      final supportDir = await getApplicationSupportDirectory();
      final supportCache = Directory(p.join(supportDir.path, 'cached_network_image'));
      return _dirSize(supportCache);
    } catch (_) {
      return 0;
    }
  }

  Future<int> _getLyricsCacheSize() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return _dirSize(Directory(p.join(dir.path, 'lyrics')));
    } catch (_) {
      return 0;
    }
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final f in dir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          total += await f.length();
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> _clearArtworkCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除封面缓存',
      content: '确定要清除封面缓存吗？这将需要重新下载封面。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    try {
      // 清除 CachedNetworkImage 的缓存目录
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(tempDir.path, 'cached_network_image'));
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        await cacheDir.create(recursive: true);
      }
    } catch (_) {}
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '封面缓存已清除');
  }

  Future<void> _clearLyricsCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除歌词缓存',
      content: '确定要清除歌词缓存吗？本地歌词会在需要时重新读取。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory(p.join(dir.path, 'lyrics'));
    if (await cacheDir.exists()) {
      try {
        await cacheDir.delete(recursive: true);
        await cacheDir.create(recursive: true);
      } catch (_) {}
    }
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '歌词缓存已清除');
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(context);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '缓存设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Watch.builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
          children: [
            AppSettingSection(
              title: '缓存管理',
              children: [
                AppSettingTile(
                  title: '封面缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '占用空间: ${_formatSize(_artworkCacheSize.value)}',
                  trailing: const Icon(Icons.image_outlined),
                  onTap: _loading.value ? null : _clearArtworkCache,
                ),
                AppSettingTile(
                  title: '歌词缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '占用空间: ${_formatSize(_lyricsCacheSize.value)}',
                  trailing: const Icon(Icons.description_outlined),
                  onTap: _loading.value ? null : _clearLyricsCache,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
