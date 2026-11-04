import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lx_script_runtime.dart';

/// 「测试」按钮里一个脚本的结果。
class LxTestRow {
  const LxTestRow(
    this.name, {
    this.ok = false,
    this.ms,
    this.format,
    this.size = 0,
    this.note = '',
  });

  final String name;
  final bool ok;

  /// 脚本取地址用了多久；没去问（不支持该平台等）为 null。
  final int? ms;

  /// FLAC / MP3 / M4A …（按文件头认的）
  final String? format;

  /// 整首字节数，拿不到为 0。
  final int size;

  /// 失败原因 / 提示。
  final String note;
}

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
            : (runtime.name.isNotEmpty ? runtime.name : '音源脚本'),
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

  /// 从订阅链接导入：下载脚本文本再走 [import]。ikun 等音源发的就是这种带
  /// key 的 .js 地址（`https://.../script/lxmusic?key=...`）。
  Future<LxSource?> importFromUrl(String url, {String? displayName}) async {
    final text = await _fetchUrl(url.trim());
    if (text == null || text.trim().isEmpty) return null;
    return import(text, displayName: displayName);
  }

  Future<String?> _fetchUrl(String url) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'lx-music-mobile/2.0');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[LX] 下载脚本失败：$e');
      return null;
    } finally {
      client?.close();
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

  /// 重命名脚本（只改显示名，不动脚本内容 / 取址逻辑）。
  Future<void> renameSource(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final i = _metas.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _metas[i] = _metas[i].copyWith(name: trimmed);
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
    String? name,
    String? singer,
    bool background = false,
    List<String> hostCovers = const [],
  }) async {
    if (!_loaded) await ensureLoaded();
    if (_runtimes.isEmpty) return null;
    final info = _musicInfo(platform, songId, name: name, singer: singer);
    // 飞牛自定义字段：App 自己会去问的后端（'gdstudio' / 'zddyr'）。认得它的
    // 脚本（如「网易专用」1.0.2+）就跳过同名后端，免得一首歌被问两遍；
    // 别的脚本不读这个键，照常工作。「测试」按钮不带它，测的是脚本完整能力。
    if (hostCovers.isNotEmpty) info['hostCovers'] = hostCovers;
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
          priority: !background,
        );
        if (url != null && url.isNotEmpty) {
          if (isPlaceholder(url, '$platform/$songId')) {
            debugPrint('[LX] ${meta.name} 给的是占位音频（不是这首歌），丢弃：$platform/$songId');
            continue;
          }
          debugPrint('[LX] ${meta.name} 命中 $platform/$songId');
          return url;
        }
      } catch (e) {
        debugPrint('[LX] ${meta.name} 取址异常：$e');
      }
    }
    return null;
  }

  /// 拉链接开头 64KB（跟随跳转），看是不是音频。给「测试」按钮用。
  /// [format] 按文件头认（FLAC / MP3 / M4A / OGG），[size] 是整首字节数（拿不到为 0）。
  @visibleForTesting
  static Future<({bool ok, String detail, String? format, int size})>
  probeAudio(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'Mozilla/5.0';
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final head = <int>[];
      await for (final chunk in resp.timeout(const Duration(seconds: 8))) {
        head.addAll(chunk);
        if (head.length >= 64) break;
      }
      final type = resp.headers.contentType?.mimeType ?? '';
      bool startsWith(String s, [int at = 0]) =>
          head.length >= at + s.length &&
          String.fromCharCodes(head.sublist(at, at + s.length)) == s;
      final isAudio =
          resp.statusCode < 400 &&
          (type.startsWith('audio/') ||
              startsWith('ID3') ||
              startsWith('fLaC') ||
              startsWith('OggS') ||
              startsWith('ftyp', 4) ||
              (head.length >= 2 &&
                  head[0] == 0xFF &&
                  (head[1] & 0xE0) == 0xE0));
      if (isAudio) {
        // Content-Range: bytes 0-65535/12345678 → 整首大小
        final range = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final total = int.tryParse(range.split('/').last) ?? resp.contentLength;
        final format = startsWith('fLaC')
            ? 'FLAC'
            : startsWith('ftyp', 4)
            ? 'M4A'
            : startsWith('OggS')
            ? 'OGG'
            : (startsWith('ID3') || (head.length >= 2 && head[0] == 0xFF))
            ? 'MP3'
            : type.replaceFirst('audio/', '').toUpperCase();
        final size = total > 0
            ? '${(total / 1048576).toStringAsFixed(1)}MB'
            : '大小未知';
        // 整首不到 1MB 多半是几秒的提示音 / 试听片段
        final tooSmall = total > 0 && total < 1048576;
        return (
          ok: !tooSmall,
          detail: tooSmall ? '只有 $size，像是提示音或片段' : '音频 $size',
          format: format,
          size: total > 0 ? total : 0,
        );
      }
      final text = String.fromCharCodes(
        head.where((b) => b >= 0x20 && b < 0x7F),
      );
      final snippet = text.length > 40 ? '${text.substring(0, 40)}…' : text;
      return (
        ok: false,
        detail: 'HTTP ${resp.statusCode}${snippet.isEmpty ? '' : '：$snippet'}',
        format: null,
        size: 0,
      );
    } catch (e) {
      return (
        ok: false,
        detail: '请求失败 ${e.runtimeType}',
        format: null,
        size: 0,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 已知只会返回占位音频的地址前缀。2026-11-05 实测：ikun（c.wwwweb.top）
  /// 的**酷狗**不管什么歌都回同一个 gitcode 上的 7 秒 mp3，「聚合音源-A」
  /// 等脚本照单全收报「命中」，播出来 7 秒就切歌；后台预取还会把整个歌单
  /// 都填成它。网易那边 ikun 给的是真地址，不受影响。
  static const List<String> _placeholderPrefixes = [
    'https://cdn-img.gitcode.com/',
  ];

  /// 地址（去掉查询串）→ 第一次拿到它的歌。真直链每首歌都不一样，同一个
  /// 地址被报给两首不同的歌，就是脚本塞的占位音频。
  final Map<String, String> _urlOwner = {};
  final Set<String> _placeholders = {};

  @visibleForTesting
  bool isPlaceholder(String url, String songKey) {
    if (_placeholderPrefixes.any(url.startsWith)) return true;
    final base = url.split('?').first;
    if (_placeholders.contains(base)) return true;
    final owner = _urlOwner[base];
    if (owner != null && owner != songKey) {
      _placeholders.add(base);
      debugPrint('[LX] 同一个地址给了两首不同的歌（$owner / $songKey），记为占位音频');
      return true;
    }
    if (_urlOwner.length > 3000) _urlOwner.clear();
    _urlOwner[base] = songKey;
    return false;
  }

  /// 平台代号 → 中文名，测试结果里显示用。
  static const Map<String, String> platformNames = {
    'wy': '网易云',
    'tx': 'QQ',
    'kg': '酷狗',
    'kw': '酷我',
    'mg': '咪咕',
  };

  /// 诊断：拿一首真实歌曲（通常是当前播放的）逐个问**所有启用**的脚本，每个
  /// 脚本一行结果。与 [resolve] 的区别是它不止于第一个命中、全部列出来，供
  /// 「测试」按钮展示。歌名歌手也要传 —— 有的脚本（溯音酷我）是按歌名搜的。
  Future<List<LxTestRow>> testRows({
    required String platform,
    required String songId,
    String quality = 'flac',
    String? name,
    String? singer,
  }) async {
    await ensureLoaded();
    final enabled = _metas.where((m) => m.enabled).toList();
    final info = _musicInfo(platform, songId, name: name, singer: singer);

    // 串行逐个测：flutter_js 原生引擎被并发驱动会互相干扰甚至闪退（和「一个
    // 一个测都能取到、全开一起测只命中一个或全崩」的现象一致），一次只问一个。
    // getMusicUrl 本身也有全局串行闸兜底，这里显式顺序跑让耗时可控、结果稳定。
    final rows = <LxTestRow>[];
    for (final meta in enabled) {
      if (!meta.sources.contains(platform)) {
        rows.add(LxTestRow(meta.name, note: '不支持这个平台'));
        continue;
      }
      final runtime = _runtimes[meta.id];
      if (runtime == null) {
        rows.add(LxTestRow(meta.name, note: '脚本没加载起来'));
        continue;
      }
      final sw = Stopwatch()..start();
      try {
        final url = await runtime.getMusicUrl(
          source: platform,
          info: info,
          quality: quality,
          timeout: const Duration(seconds: 8),
        );
        sw.stop();
        final ms = sw.elapsedMilliseconds;
        if (url == null || url.isEmpty) {
          rows.add(LxTestRow(meta.name, ms: ms, note: '没取到'));
        } else if (_placeholderPrefixes.any(url.startsWith)) {
          rows.add(LxTestRow(meta.name, ms: ms, note: '占位音频，不是这首歌'));
        } else {
          // 有的脚本（全豆要的长青 / 念心）只是把 id 拼进固定链接就当「拿到了」，
          // 不管有没有这首歌都秒回 —— 只看「返回了链接」会误报 ✅。真去拉开头
          // 一小段，确认是音频才算数。
          final probe = await probeAudio(url);
          rows.add(
            LxTestRow(
              meta.name,
              ok: probe.ok,
              ms: ms,
              format: probe.format,
              size: probe.size,
              note: probe.ok ? '' : probe.detail,
            ),
          );
        }
      } catch (e) {
        rows.add(LxTestRow(meta.name, note: '出错：$e'));
      }
    }
    return rows;
  }

  /// 构造传给脚本的 musicInfo（洛雪 info.musicInfo）。酷狗(kg)用 hash、其余
  /// 平台用 songmid；多塞几个常见 id 键（mid/id/copyrightId），脚本读哪个都能命中。
  /// 非 kg **不塞 hash**：脚本常用 `musicInfo.hash ?? musicInfo.songmid`，空串 ''
  /// 不是 nullish，会让 ?? 返回空串、songmid 永远取不到。
  static Map<String, dynamic> _musicInfo(
    String platform,
    String songId, {
    String? name,
    String? singer,
  }) {
    final info = <String, dynamic>{
      'songmid': songId,
      'mid': songId,
      'id': songId,
      'copyrightId': songId,
      'songId': songId,
    };
    if (platform == 'kg') info['hash'] = songId;
    // 有些后端（尤其咪咕）按歌名+歌手搜，没有就报「需要 name+singer」。给上。
    if (name != null && name.isNotEmpty) {
      info['name'] = name;
      info['songName'] = name;
    }
    if (singer != null && singer.isNotEmpty) {
      info['singer'] = singer;
      info['artist'] = singer;
    }
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

  /// 备份：导出所有已导入脚本的文本（id → 脚本），文件丢了的跳过。
  Future<Map<String, String>> exportScripts() async {
    await ensureLoaded();
    final out = <String, String>{};
    for (final meta in _metas) {
      try {
        final file = await _fileFor(meta.id);
        if (await file.exists()) out[meta.id] = await file.readAsString();
      } catch (_) {}
    }
    return out;
  }

  /// 还原：把备份里的脚本文本写回 `lx_sources/<id>.js`（索引随偏好一起还原）。
  Future<int> importScripts(Map<String, String> scripts) async {
    var count = 0;
    for (final entry in scripts.entries) {
      // id 是导入时的微秒时间戳，只认纯数字，防止备份里塞路径
      if (!RegExp(r'^[0-9]{1,20}$').hasMatch(entry.key)) continue;
      try {
        final file = await _fileFor(entry.key);
        await file.writeAsString(entry.value);
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// 备份还原后调用：丢掉内存里的旧状态，按存档重新读一遍（否则下次保存会把还原的数据覆盖回去）。
  Future<void> reloadFromStorage() async {
    await ensureLoaded();
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
    _metas.clear();
    _loaded = false;
    _loadFuture = null;
    await ensureLoaded();
    _bump();
  }
}
