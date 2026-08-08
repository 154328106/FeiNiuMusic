import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';

/// 插件存储：插件文件在 `应用支持目录/plugins/<id>/`，元数据（manifest +
/// 启用/配置）存 SharedPreferences（key 为 `plugin_installed_<id>`）。
class PluginStore {
  PluginStore._internal();

  static final PluginStore instance = PluginStore._internal();

  static const String _prefsIndex = 'plugin_installed_ids';
  static const String _prefsPluginPrefix = 'plugin_installed_';

  /// 插件缓存根目录（QuickJsHostApi cache.* 用，按插件 id 分目录）。
  String? cacheRootDir;

  Future<String> _pluginsRoot() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'plugins');
  }

  /// 已安装插件列表（按 sortOrder 排序）。
  Future<List<InstalledPlugin>> getPlugins() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsIndex) ?? [];
    final result = <InstalledPlugin>[];
    for (final id in ids) {
      final json = prefs.getString('$_prefsPluginPrefix$id');
      if (json == null) continue;
      try {
        final plugin = InstalledPlugin.fromJson(
            jsonDecode(json) as Map<String, dynamic>);
        result.add(plugin);
      } catch (_) {
        // 损坏条目忽略
      }
    }
    result.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return result;
  }

  /// 按传入顺序重排插件（数据源维护页拖动排序）：按顺序重写各插件的
  /// sortOrder（0..n）并持久化。
  Future<void> reorderPlugins(List<InstalledPlugin> ordered) async {
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < ordered.length; i++) {
      final plugin = ordered[i];
      if (plugin.sortOrder == i) continue;
      final updated = InstalledPlugin(
        manifest: plugin.manifest,
        dirPath: plugin.dirPath,
        enabled: plugin.enabled,
        metadataEnabled: plugin.metadataEnabled,
        lyricsEnabled: plugin.lyricsEnabled,
        coverEnabled: plugin.coverEnabled,
        config: plugin.config,
        sortOrder: i,
      );
      await prefs.setString(
        '$_prefsPluginPrefix${updated.manifest.id}',
        jsonEncode(updated.toJson()),
      );
    }
  }

  /// 按 id 获取插件（未安装返回 null）。
  Future<InstalledPlugin?> getPlugin(String id) async {
    final plugins = await getPlugins();
    for (final p in plugins) {
      if (p.manifest.id == id) return p;
    }
    return null;
  }

  /// 写入/更新插件元数据。
  Future<void> upsertPlugin(InstalledPlugin plugin) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsIndex) ?? [];
    if (!ids.contains(plugin.manifest.id)) {
      ids.add(plugin.manifest.id);
      await prefs.setStringList(_prefsIndex, ids);
    }
    await prefs.setString(
      '$_prefsPluginPrefix${plugin.manifest.id}',
      jsonEncode(plugin.toJson()),
    );
  }

  /// 卸载插件：删除文件目录 + 清理 prefs 元数据。
  Future<void> removePlugin(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsIndex) ?? [];
    await prefs.setStringList(_prefsIndex, ids.where((x) => x != id).toList());
    await prefs.remove('$_prefsPluginPrefix$id');

    final root = await _pluginsRoot();
    final dir = Directory(p.join(root, id));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// 已安装插件的文件目录（插件 id → 目录路径）。
  Future<String> pluginDir(String id) async {
    final root = await _pluginsRoot();
    return p.join(root, id);
  }

  /// 读取插件 manifest.json（从插件目录）。
  Future<PluginManifest?> readManifest(String dirPath) async {
    final file = File(p.join(dirPath, 'manifest.json'));
    if (!file.existsSync()) return null;
    try {
      final map =
          jsonDecode(utf8.decode(file.readAsBytesSync())) as Map<String, dynamic>;
      return PluginManifest.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// 初始化缓存根目录（供 QuickJsHostApi cache.*）。
  Future<void> ensureCacheRoot() async {
    final dir = await getApplicationSupportDirectory();
    cacheRootDir = p.join(dir.path, 'plugin_cache');
    await Directory(cacheRootDir!).create(recursive: true);
  }
}
