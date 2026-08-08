import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'plugin_manifest.dart';

/// 插件 zip 导入器（移植 Lyrico SourcePluginInstaller 的安全校验逻辑）。
///
/// - 解压 zip（archive 包），扫描 `manifest.json` 列出可安装插件；
/// - 安全校验：拒绝绝对路径 / `..` / 反斜杠 / NUL / 深层嵌套，镜像
///   Lyrico 的 `isSafeRelativePath` 与 zip 条目校验；
/// - 限制：manifest ≤128KB、入口 .js ≤1MB、单插件 ≤5MB、每包 ≤20 个插件、
///   文件数 ≤1000、解压总量 ≤30MB、深度 ≤16。
class PluginImporter {
  static const int maxManifestBytes = 128 * 1024;
  static const int maxEntryScriptBytes = 1 * 1024 * 1024;
  static const int maxSinglePluginBytes = 5 * 1024 * 1024;
  static const int maxPluginCount = 20;
  static const int maxFileCount = 1000;
  static const int maxTotalBytes = 30 * 1024 * 1024;
  static const int maxDepth = 16;

  /// 从 zip 字节中识别可安装的插件清单（不落盘）。
  ///
  /// 返回每个 manifest 所在的 zip 相对目录（以 `/` 结尾的目录前缀），
  /// 供 [extractPlugin] 解压对应目录。
  List<PluginImportCandidate> inspectZip(List<int> zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    if (archive.files.length > maxFileCount) {
      throw const FormatException('插件包内文件过多');
    }

    var totalBytes = 0;
    for (final file in archive.files) {
      totalBytes += file.size;
      if (totalBytes > maxTotalBytes) {
        throw const FormatException('插件包解压后过大');
      }
      _validateZipEntryName(file.name);
      if (file.name.split('/').length > maxDepth) {
        throw const FormatException('插件包内目录过深');
      }
    }

    final manifests = <PluginImportCandidate>[];
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name;
      if (p.basename(name) != 'manifest.json') continue;

      final bytes = file.content as List<int>;
      if (bytes.length > maxManifestBytes) {
        throw FormatException('$name: manifest 过大');
      }
      final manifest = _parseManifest(bytes);
      _validateManifest(manifest);
      final rootDir = p.posix.dirname(name);
      final root = rootDir == '.' ? '' : rootDir;

      // 校验入口与 includeDirs 存在
      final entryPath = root.isEmpty ? manifest.entry : '$root/${manifest.entry}';
      final hasEntry = archive.files.any((f) =>
          f.isFile && _normalizePosix(f.name) == _normalizePosix(entryPath));
      if (!hasEntry) {
        throw FormatException('${manifest.name}: 入口脚本 ${manifest.entry} 不存在');
      }
      for (final dir in manifest.includeDirs) {
        final dirPath = root.isEmpty ? dir : '$root/$dir';
        if (!_archiveHasDir(archive, dirPath)) {
          throw FormatException(
              '${manifest.name}: includeDir $dir 不存在');
        }
      }

      manifests.add(PluginImportCandidate(
        manifest: manifest,
        rootInArchive: root,
      ));
    }

    if (manifests.isEmpty) {
      throw const FormatException('插件包内未找到 manifest.json');
    }

    // 去重：同 id 在包内出现多次 → 报错
    final ids = manifests.map((c) => c.manifest.id).toList();
    final dup = ids.toSet().where((id) => ids.where((x) => x == id).length > 1);
    if (dup.isNotEmpty) {
      throw FormatException('插件包内存在重复插件 id: ${dup.join(', ')}');
    }
    if (manifests.length > maxPluginCount) {
      throw const FormatException('插件包内插件过多');
    }

    return manifests;
  }

  /// 从 zip 字节中解压单个插件（[rootInArchive] 为 manifest 所在目录）到
  /// [destDir]（目标插件目录，通常是 `<pluginsRoot>/<id>`）。
  Future<void> extractPlugin(
    List<int> zipBytes,
    String rootInArchive,
    String destDir,
  ) async {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    final rootPrefix = rootInArchive.isEmpty ? '' : '$rootInArchive/';

    final dir = Directory(destDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    var totalSize = 0;
    for (final file in archive.files) {
      final name = file.name;
      if (rootPrefix.isNotEmpty &&
          !name.startsWith(rootPrefix) &&
          name != rootInArchive) {
        continue;
      }
      // 相对插件根目录的路径
      var rel = name;
      if (rel.startsWith(rootPrefix)) {
        rel = rel.substring(rootPrefix.length);
      } else if (rel == rootInArchive) {
        continue;
      }
      _validateZipEntryName(rel);
      if (rel.isEmpty) continue;

      final target = p.join(destDir, rel);
      if (!_isUnder(target, destDir)) {
        throw const FormatException('非法路径穿越');
      }

      if (file.isFile) {
        final bytes = file.content as List<int>;
        totalSize += bytes.length;
        if (totalSize > maxSinglePluginBytes) {
          throw const FormatException('插件过大');
        }
        final f = File(target);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
      } else {
        Directory(target).createSync(recursive: true);
      }
    }
  }

  // ---- 校验 ----

  void _validateManifest(PluginManifest m) {
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$')
        .hasMatch(m.id)) {
      throw FormatException('插件 id 必须是反向域名格式: ${m.id}');
    }
    if (m.name.isEmpty) throw const FormatException('插件 name 不能为空');
    if (m.versionCode < 1) {
      throw FormatException('插件 versionCode 必须 ≥ 1');
    }
    if (m.apiVersion < 1 || m.apiVersion > 4) {
      throw FormatException('不支持的 apiVersion: ${m.apiVersion}');
    }
    if (m.minHostApiVersion < 1 || m.minHostApiVersion > 3) {
      throw FormatException('不支持的 minHostApiVersion: ${m.minHostApiVersion}');
    }
    if (!_isSafeRelativePath(m.entry) ||
        !m.entry.toLowerCase().endsWith('.js')) {
      throw FormatException('非法入口路径: ${m.entry}');
    }
    for (final dir in m.includeDirs) {
      if (!_isSafeRelativePath(dir) || dir == '.') {
        throw FormatException('非法 includeDir: $dir');
      }
    }
  }

  PluginManifest _parseManifest(List<int> bytes) {
    try {
      final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return PluginManifest.fromJson(map);
    } catch (e) {
      throw FormatException('manifest 解析失败: $e');
    }
  }

  void _validateZipEntryName(String entryName) {
    if (entryName.isEmpty) throw const FormatException('zip 条目名为空');
    if (entryName.contains('\u0000')) throw const FormatException('zip 条目含 NUL');
    if (entryName.startsWith('/') || entryName.startsWith('\\')) {
      throw const FormatException('zip 条目不允许绝对路径');
    }
    if (entryName.contains('\\')) {
      throw const FormatException('zip 条目不允许反斜杠');
    }
    if (entryName.split('/').any((s) => s == '..')) {
      throw const FormatException('zip 条目不允许 ..');
    }
  }

  bool _isSafeRelativePath(String path) {
    if (path.isEmpty) return false;
    if (path.startsWith('/') || path.startsWith('\\')) return false;
    if (path.contains('\\') || path.contains('\u0000')) return false;
    return path.split('/').every((s) => s.isNotEmpty && s != '..');
  }

  bool _isUnder(String path, String base) {
    final normalizedPath = p.normalize(path);
    final normalizedBase = p.normalize(base);
    return normalizedPath == normalizedBase ||
        normalizedPath.startsWith('$normalizedBase${Platform.pathSeparator}');
  }

  bool _archiveHasDir(Archive archive, String dirPath) {
    final prefix = _normalizePosix(dirPath);
    return archive.files.any((f) =>
        f.name == prefix ||
        f.name.startsWith('$prefix/') ||
        f.name == '$prefix/');
  }

  String _normalizePosix(String path) => p.posix.normalize(path);
}

/// 一个可安装的插件候选。
class PluginImportCandidate {
  final PluginManifest manifest;
  final String rootInArchive;

  const PluginImportCandidate({
    required this.manifest,
    required this.rootInArchive,
  });
}
