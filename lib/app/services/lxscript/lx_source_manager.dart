import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lx_script_runtime.dart';

/// 一条已导入的 LX 脚本音源的元数据。
class LxSource {
  const LxSource({
    required this.id,
    required this.name,
    required this.enabled,
    required this.sources,
  });

  final String id;
  final String name;
  final bool enabled;

  /// 脚本声明支持的平台代号（wy/tx/kg/kw/mg…）。
  final List<String> sources;

  LxSource copyWith({String? name, bool? enabled, List<String>? sources}) =>
      LxSource(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        sources: sources ?? this.sources,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'sources': sources,
  };

  static LxSource fromJson(Map<String, dynamic> j) => LxSource(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    enabled: (j['enabled'] as bool?) ?? true,
    sources: ((j['sources'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
  );
}

/// LX（洛雪）脚本音源管理器。
///
/// 存储：脚本文本放 `getApplicationSupportDirectory()/lx_sources/<id>.js`，
/// 元数据索引放 SharedPreferences（一条 JSON 数组）。启用的脚本在
/// [ensureLoaded] 时各起一个 [LxScriptRuntime]。
///
/// 解灰链（`UnblockSourceService.resolve`）在聆澜之后、关键词兜底之前调
/// [resolve]：挑第一个「启用 + 声明支持该平台」的脚本取址，命中即返回。
class LxSourceManager {
  static final LxSourceManager instance = LxSourceManager._();
  LxSourceManager._();

  static const String _prefsKey = 'lx_sources_index';
  static const String _dirName = 'lx_sources';

  final List<LxSource> _metas = [];
  final Map<String, LxScriptRuntime> _runtimes = {};
  bool _loaded = false;
  Future<void>? _loadFuture;

  /// 列表变化时自增，供设置页刷新。
  final ValueNotifier<int> revision = ValueNotifier(0);

  List<LxSource> list() => List.unmodifiable(_metas);

  bool get hasEnabled => _metas.any((m) => m.enabled);

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefsKey);
        if (raw != null) {
          final list = jsonDecode(raw) as List;
          _metas
            ..clear()
            ..addAll(
              list.map((e) => LxSource.fromJson(e as Map<String, dynamic>)),
            );
        }
        for (final meta in _metas.where((m) => m.enabled)) {
          await _spawn(meta);
        }
      } catch (e) {
        debugPrint('[LX] 载入脚本索引失败：$e');
      } finally {
        _loaded = true;
        _loadFuture = null;
      }
    }();
  }

  /// 导入脚本文本。成功返回元数据（含脚本声明的 sources）；失败返回 null。
  Future<LxSource?> import(String scriptText, {String? displayName}) async {
    await ensureLoaded();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      final file = await _fileFor(id);
      await file.writeAsString(scriptText);
      // 先起一个运行时验证并取 sources。
      final runtime = LxScriptRuntime();
      final ok = await runtime.load(scriptText);
      if (!ok) {
        runtime.dispose();
        await file.delete().catchError((_) => file);
        return null;
      }
      final meta = LxSource(
        id: id,
        name: displayName?.trim().isNotEmpty == true
            ? displayName!.trim()
            : (runtime.name.isNotEmpty ? runtime.name : 'LX 脚本音源'),
        enabled: true,
        sources: runtime.sources,
      );
      _runtimes[id] = runtime;
      _metas.insert(0, meta);
      await _persist();
      _bump();
      return meta;
    } catch (e) {
      debugPrint('[LX] 导入失败：$e');
      return null;
    }
  }

  Future<void> remove(String id) async {
    _runtimes.remove(id)?.dispose();
    _metas.removeWhere((m) => m.id == id);
    try {
      final file = await _fileFor(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await _persist();
    _bump();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _metas.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _metas[i] = _metas[i].copyWith(enabled: enabled);
    if (enabled) {
      if (!_runtimes.containsKey(id)) await _spawn(_metas[i]);
    } else {
      _runtimes.remove(id)?.dispose();
    }
    await _persist();
    _bump();
  }

  /// 解灰链调用：挑第一个启用且声明支持 [platform] 的脚本取址。
  Future<String?> resolve({
    required String platform,
    required String songId,
    String quality = 'flac',
  }) async {
    if (!_loaded) await ensureLoaded();
    if (_runtimes.isEmpty) return null;
    final info = _musicInfo(platform, songId);
    for (final meta in _metas) {
      if (!meta.enabled) continue;
      if (!meta.sources.contains(platform)) continue;
      final runtime = _runtimes[meta.id];
      if (runtime == null) continue;
      try {
        // 播放解灰链是逐个等的，给个更短超时：卡住的脚本别拖慢起播。
        final url = await runtime.getMusicUrl(
          source: platform,
          info: info,
          quality: quality,
          timeout: const Duration(seconds: 6),
        );
        if (url != null && url.isNotEmpty) {
          debugPrint('[LX] ${meta.name} 命中 $platform/$songId');
          return url;
        }
      } catch (e) {
        debugPrint('[LX] ${meta.name} 取址异常：$e');
      }
    }
    return null;
  }

  /// 诊断：拿一首真实歌曲（通常是当前播放的）逐个问**所有启用**的脚本，
  /// 返回逐条报告（命中给 URL 前缀、空/异常如实写）。与 [resolve] 的区别是它
  /// 不止于第一个命中、把每个脚本的结果都列出来，供「测试」按钮展示。
  Future<String> testReport({
    required String platform,
    required String songId,
    String quality = 'flac',
  }) async {
    await ensureLoaded();
    final enabled = _metas.where((m) => m.enabled).toList();
    if (enabled.isEmpty) return '没有启用的脚本。';
    final info = _musicInfo(platform, songId);

    // 并行测所有支持该平台的脚本：一个卡住不拖累其它，整体最多等一个超时。
    final lines = List<String>.filled(enabled.length, '');
    var tested = 0;
    final futures = <Future<void>>[];
    for (var i = 0; i < enabled.length; i++) {
      final meta = enabled[i];
      if (!meta.sources.contains(platform)) {
        lines[i] = '• ${meta.name}：不支持 $platform，跳过';
        continue;
      }
      final runtime = _runtimes[meta.id];
      if (runtime == null) {
        lines[i] = '• ${meta.name}：运行时未就绪';
        continue;
      }
      tested++;
      futures.add(() async {
        final sw = Stopwatch()..start();
        try {
          final url = await runtime.getMusicUrl(
            source: platform,
            info: info,
            quality: quality,
          );
          sw.stop();
          if (url != null && url.isNotEmpty) {
            final head = url.length > 72 ? '${url.substring(0, 72)}…' : url;
            lines[i] = '• ${meta.name}：✅ ${sw.elapsedMilliseconds}ms\n  $head';
          } else {
            lines[i] =
                '• ${meta.name}：⚠️ 没取到（该源无此曲 / 后端无货，${sw.elapsedMilliseconds}ms）';
          }
        } catch (e) {
          lines[i] = '• ${meta.name}：❌ 异常 $e';
        }
      }());
    }
    await Future.wait(futures);

    final buf = StringBuffer('平台 $platform · id $songId\n')
      ..writeln(lines.where((l) => l.isNotEmpty).join('\n'));
    if (tested == 0) {
      buf.writeln('\n（没有脚本声明支持 $platform —— 换一首该平台的歌再测）');
    }
    return buf.toString().trim();
  }

  /// 构造传给脚本的 musicInfo（洛雪 info.musicInfo）。酷狗(kg)用 hash、其余
  /// 平台用 songmid；多塞几个常见 id 键（mid/id/copyrightId），脚本读哪个都能命中。
  /// 非 kg **不塞 hash**：脚本常用 `musicInfo.hash ?? musicInfo.songmid`，空串 ''
  /// 不是 nullish，会让 ?? 返回空串、songmid 永远取不到。
  static Map<String, dynamic> _musicInfo(String platform, String songId) {
    final info = <String, dynamic>{
      'songmid': songId,
      'mid': songId,
      'id': songId,
      'copyrightId': songId,
      'songId': songId,
    };
    if (platform == 'kg') info['hash'] = songId;
    return info;
  }

  // ---- 内部 ----

  Future<void> _spawn(LxSource meta) async {
    try {
      final file = await _fileFor(meta.id);
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final runtime = LxScriptRuntime();
      final ok = await runtime.load(text);
      if (ok) {
        _runtimes[meta.id] = runtime;
        // 刷新 sources（脚本可能更新了声明）。
        final i = _metas.indexWhere((m) => m.id == meta.id);
        if (i >= 0 && runtime.sources.isNotEmpty) {
          _metas[i] = _metas[i].copyWith(sources: runtime.sources);
        }
      } else {
        runtime.dispose();
      }
    } catch (e) {
      debugPrint('[LX] 启动脚本 ${meta.id} 失败：$e');
    }
  }

  Future<File> _fileFor(String id) async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, _dirName),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '$id.js'));
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(_metas.map((m) => m.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[LX] 保存索引失败：$e');
    }
  }

  void _bump() => revision.value = revision.value + 1;
}
