import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/dao/download_dao.dart';
import '../feiniu/api_client.dart';
import '../kugou/kugou_playback_service.dart';
import '../kuwo/kuwo_playback_service.dart';
import '../migu/migu_playback_service.dart';
import '../netease/netease_api_client.dart';
import '../netease/netease_playback_service.dart';
import '../qq/qq_playback_service.dart';
import '../unblock/unblock_source.dart';
import '../../state/song_source.dart';
import '../../state/song_state.dart';

/// 一个可下载的音质档位。[id] 是传给各源取址的参数（网易 level / 兜底占位），
/// [label] 给用户看、也入库展示。
class DownloadQualityOption {
  const DownloadQualityOption(this.id, this.label);
  final String id;
  final String label;
}

/// 取址结果：下载用的直链 + 该直链需要的请求头。
class _ResolvedDownload {
  const _ResolvedDownload(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

/// 本地下载管理器 —— 跨源把歌曲下到 App 私有持久目录，入库，供「本地」页浏览、
/// 供播放器离线命中。
///
/// 与 [StreamCacheService] 的区别：那是 `getTemporaryDirectory()` 下的**易失**
/// 播放加速缓存（系统可清、按上限淘汰、不可浏览）；这里是
/// `getApplicationDocumentsDirectory()/downloads/` 下的**持久**文件，只有用户
/// 主动删除或卸载 App 才会消失。
class DownloadService {
  static final DownloadService instance = DownloadService._();
  DownloadService._();

  static const String dirName = 'downloads';

  /// `songId → 本地文件绝对路径`，播放热路径同步命中用。[ensureLoaded] 填充。
  final Map<String, String> _paths = {};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Directory? _dir;

  /// 进行中下载的进度：`songId → 0..1`（总长未知时为 -1，UI 显示不确定进度）。
  final ValueNotifier<Map<String, double>> progress = ValueNotifier({});

  /// 任一下载完成/删除时自增，供列表页/入口刷新已下载状态。
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// 从数据库载入 `id → path` 映射（幂等，只做一次）。应在 App 启动时调用一次，
  /// 保证播放热路径 [localFileFor] 同步可用。
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= () async {
      try {
        final map = await DownloadDao.instance.idToPath();
        _paths
          ..clear()
          ..addAll(map);
        // 老版本下载在内部私有目录，挪到外部可见目录（后台，不阻塞首帧）。
        unawaited(_migrateToVisibleDir());
      } catch (e) {
        debugPrint('[Download] 载入下载记录失败：$e');
      } finally {
        _loaded = true;
        _loadFuture = null;
      }
    }();
  }

  /// 已下载到本地的文件（存在才返回）。未载入或未命中返回 null。
  ///
  /// 播放热路径（`PlayerService._sourceForSong` 顶部）同步调用：不 await、不出网。
  /// 未载入时顺手触发一次后台载入，下次即可命中。
  File? localFileFor(String songId) {
    if (!_loaded) {
      unawaited(ensureLoaded());
      return null;
    }
    final path = _paths[songId];
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) {
      // 文件被外部清掉但库里还在：顺手剔除，避免反复命中空路径。
      _paths.remove(songId);
      unawaited(DownloadDao.instance.delete(songId));
      return null;
    }
    return file;
  }

  bool isDownloaded(String songId) => _paths.containsKey(songId);

  bool isDownloading(String songId) => progress.value.containsKey(songId);

  double? progressOf(String songId) => progress.value[songId];

  /// 某个源实际能选的档位。网易全阶可选；飞牛给原始；酷狗/QQ 走公益源链
  /// 「最佳可得」一档（取址本就奔最高去，无法真·降档）。
  List<DownloadQualityOption> qualityOptionsFor(SongSource source) {
    switch (source) {
      case SongSource.netease:
        return const [
          DownloadQualityOption('standard', '标准'),
          DownloadQualityOption('exhigh', '极高'),
          DownloadQualityOption('lossless', '无损'),
          DownloadQualityOption('hires', 'Hi-Res'),
        ];
      case SongSource.feiniu:
        return const [DownloadQualityOption('original', '原始音质')];
      case SongSource.kugou:
      case SongSource.qq:
      case SongSource.kuwo:
      case SongSource.migu:
        return const [DownloadQualityOption('best', '最佳可得')];
    }
  }

  /// 下载目录。Android 放到**外部**应用目录（`Android/data/<包名>/files/
  /// downloads`）——手机文件管理器 / 连电脑都能看到、能管理；且无需任何存储
  /// 权限。拿不到外部目录才退回内部 Documents。iOS/桌面仍用 Documents
  /// （iOS 已开 UIFileSharingEnabled，「文件」App 里可见）。
  Future<Directory> _downloadsDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    Directory base;
    try {
      if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        base = Directory(
          p.join(ext?.path ?? (await getApplicationDocumentsDirectory()).path, dirName),
        );
      } else {
        base = Directory(
          p.join((await getApplicationDocumentsDirectory()).path, dirName),
        );
      }
    } catch (_) {
      base = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, dirName),
      );
    }
    if (!await base.exists()) await base.create(recursive: true);
    _dir = base;
    return base;
  }

  /// 下载目录的绝对路径（给「本地」页展示/跳转用）。
  Future<String> downloadsDirPath() async => (await _downloadsDir()).path;

  /// 把旧的内部私有目录（Documents/downloads）里的文件迁到新的外部可见目录，
  /// 并更新库里的路径。幂等：已在新目录的跳过。[ensureLoaded] 后台调一次。
  Future<void> _migrateToVisibleDir() async {
    if (!Platform.isAndroid) return;
    try {
      final target = await _downloadsDir();
      final docs = await getApplicationDocumentsDirectory();
      final oldDir = Directory(p.join(docs.path, dirName));
      if (oldDir.path == target.path || !await oldDir.exists()) return;
      var moved = 0;
      for (final entry in _paths.entries.toList()) {
        final id = entry.key;
        final oldPath = entry.value;
        if (!oldPath.startsWith(oldDir.path)) continue;
        final src = File(oldPath);
        if (!await src.exists()) continue;
        final newPath = p.join(target.path, p.basename(oldPath));
        try {
          await src.rename(newPath);
        } catch (_) {
          // 跨卷 rename 失败就复制再删。
          await src.copy(newPath);
          try {
            await src.delete();
          } catch (_) {}
        }
        _paths[id] = newPath;
        await DownloadDao.instance.updatePath(id, newPath);
        moved++;
      }
      if (moved > 0) {
        debugPrint('[Download] 迁移 $moved 个文件到可见目录');
        _bumpRevision();
      }
    } catch (e) {
      debugPrint('[Download] 迁移失败：$e');
    }
  }

  /// 下载文件名（无扩展名）：`歌名 - 歌手`，便于在系统「文件」App 里辨认；
  /// 末尾加 6 位 id 短哈希保唯一，避免同名歌互相覆盖、同一首重下又命中自己。
  /// 去掉文件名非法字符（Windows/iOS 都忌 `\/:*?"<>|`），长度截断。
  static String _downloadBaseName(SongEntity song) {
    final title = song.title.trim();
    final artist = song.artistDisplayName.trim();
    var name = artist.isEmpty ? title : '$title - $artist';
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (name.length > 80) name = name.substring(0, 80).trim();
    if (name.isEmpty) name = 'song';
    final shortId = md5
        .convert(utf8.encode(song.id))
        .toString()
        .substring(0, 6);
    return '${name}_$shortId';
  }

  /// 下载一首歌。[qualityId] 来自 [qualityOptionsFor]；[qualityLabel] 入库展示。
  ///
  /// 已下载或下载中直接返回。失败抛异常（调用方 toast）。
  Future<void> download(
    SongEntity song, {
    required String qualityId,
    required String qualityLabel,
  }) async {
    await ensureLoaded();
    final id = song.id;
    if (isDownloaded(id) || isDownloading(id)) return;

    _setProgress(id, -1);
    try {
      final source = SongSource.fromSongId(id);
      final resolved = await _resolveForDownload(song, source, qualityId);
      if (resolved == null) {
        throw StateError('取不到可下载的地址');
      }
      final dir = await _downloadsDir();
      final base = p.join(dir.path, _downloadBaseName(song));
      final result = await _httpDownloadToFile(
        resolved.url,
        resolved.headers,
        song,
        base,
        (received, total) {
          _setProgress(id, total > 0 ? received / total : -1);
        },
      );

      final fileSize = await result.length();
      await DownloadDao.instance.upsert(
        DownloadRecord(
          song: song,
          localPath: result.path,
          source: source,
          quality: qualityLabel,
          fileSize: fileSize,
          downloadedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _paths[id] = result.path;
      _bumpRevision();
    } finally {
      _clearProgress(id);
    }
  }

  /// 删除一首已下载的歌（文件 + 库记录 + 内存映射）。
  Future<void> delete(String songId) async {
    final path = _paths.remove(songId);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    await DownloadDao.instance.delete(songId);
    _bumpRevision();
  }

  /// 全部已下载记录（最新在前）。
  Future<List<DownloadRecord>> all() => DownloadDao.instance.all();

  /// 全部下载文件占用字节数。
  Future<int> totalSize() async {
    try {
      final dir = await _downloadsDir();
      if (!await dir.exists()) return 0;
      var sum = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            sum += await entity.length();
          } catch (_) {}
        }
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  // ---- 取址（按源 + 档位） ----

  Future<_ResolvedDownload?> _resolveForDownload(
    SongEntity song,
    SongSource source,
    String qualityId,
  ) async {
    switch (source) {
      case SongSource.netease:
        final neteaseId = SongSource.decodeNetease(song.id);
        if (neteaseId == null) return null;
        // 先按选中的档位走官方；官方给不出/只给试听片段 → 第三方音源兜底。
        final official = await NetEaseApiClient.instance.songUrls([
          neteaseId,
        ], level: qualityId);
        final info = official[neteaseId];
        final url = info?.url;
        if (url != null && !(info?.freeTrial ?? false)) {
          return _ResolvedDownload(
            _https(url),
            NetEasePlaybackService.streamHeaders(),
          );
        }
        final unblocked = await UnblockSourceService.instance.resolve(
          platform: 'wy',
          songId: '$neteaseId',
        );
        if (unblocked != null) {
          // 公益源直链是公开地址，不要带网易 CDN 的 Referer（反而可能被拒）。
          return _ResolvedDownload(_https(unblocked), const {});
        }
        return null;
      case SongSource.qq:
        final mid = SongSource.decodeQQ(song.id);
        if (mid == null) return null;
        final url = await QQPlaybackService.instance.resolveStreamUrl(
          mid,
          mediaMid: song.audioSpec,
        );
        if (url == null) return null;
        return _ResolvedDownload(url, QQPlaybackService.streamHeaders());
      case SongSource.kugou:
        final hash = SongSource.decodeKugou(song.id);
        if (hash == null) return null;
        final url = await KugouPlaybackService.instance.resolveStreamUrl(hash);
        if (url == null) return null;
        return _ResolvedDownload(url, KugouPlaybackService.streamHeaders());
      case SongSource.kuwo:
        final rid = SongSource.decodeKuwo(song.id);
        if (rid == null) return null;
        final url = await KuwoPlaybackService.instance.resolveStreamUrl(rid);
        if (url == null) return null;
        return _ResolvedDownload(url, KuwoPlaybackService.streamHeaders());
      case SongSource.migu:
        final cid = SongSource.decodeMigu(song.id);
        if (cid == null) return null;
        final url = await MiguPlaybackService.instance.resolveStreamUrl(cid, song: song);
        if (url == null) return null;
        return _ResolvedDownload(url, MiguPlaybackService.streamHeaders());
      case SongSource.feiniu:
        final api = FeiNiuApiClient.instance;
        if (api.baseUrl.isEmpty) return null;
        return _ResolvedDownload(
          api.streamUrl(song.id),
          FeiNiuApiClient.imageAuthHeaders(),
        );
    }
  }

  static String _https(String url) =>
      url.startsWith('http://') ? url.replaceFirst('http://', 'https://') : url;

  // ---- 流式下载到文件 ----

  /// 下载 [url] 到 `<base>.<ext>`（扩展名按响应 Content-Type / 歌曲格式推断），
  /// 经 `.part` 原子落盘。返回最终文件。
  Future<File> _httpDownloadToFile(
    String url,
    Map<String, String> headers,
    SongEntity song,
    String base,
    void Function(int received, int total) onProgress,
  ) async {
    // 继承 main.dart 的 HttpOverrides.global（SSL 忽略全局生效，飞牛自签名/
    // 公益源出口证书问题都在那层处理）。不自动解压，保证字节与线上一致。
    final client = HttpClient()..autoUncompress = false;
    final partFile = File('$base.part');
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final ext = _extensionFor(
        response.headers.contentType?.toString(),
        url,
        song.format,
      );
      final finalFile = File('$base.$ext');
      final total = response.contentLength;
      await partFile.create(recursive: true);
      sink = partFile.openWrite();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(received, total);
      }
      await sink.close();
      sink = null;
      if (await finalFile.exists()) await finalFile.delete();
      await partFile.rename(finalFile.path);
      return finalFile;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 按 Content-Type / URL 后缀 / 歌曲格式推断文件扩展名，兜底 mp3。
  static String _extensionFor(String? contentType, String url, String? format) {
    final mime = contentType?.toLowerCase() ?? '';
    if (mime.contains('flac')) return 'flac';
    if (mime.contains('mp3') || mime.contains('mpeg')) return 'mp3';
    if (mime.contains('m4a') || mime.contains('aac') || mime.contains('mp4')) {
      return 'm4a';
    }
    if (mime.contains('ogg')) return 'ogg';
    if (mime.contains('wav')) return 'wav';
    // URL 路径后缀
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const [
      'flac',
      'mp3',
      'm4a',
      'aac',
      'ogg',
      'wav',
      'ape',
    ]) {
      if (path.endsWith('.$ext')) return ext == 'aac' ? 'm4a' : ext;
    }
    // 歌曲自带格式
    final f = format?.trim().toLowerCase();
    if (f != null && f.isNotEmpty) {
      const map = {
        'mp3': 'mp3',
        'flac': 'flac',
        'm4a': 'm4a',
        'aac': 'm4a',
        'ogg': 'ogg',
        'wav': 'wav',
        'ape': 'ape',
      };
      final mapped = map[f];
      if (mapped != null) return mapped;
    }
    return 'mp3';
  }

  // ---- 进度/通知 ----

  void _setProgress(String id, double value) {
    final next = Map<String, double>.from(progress.value);
    next[id] = value;
    progress.value = next;
  }

  void _clearProgress(String id) {
    if (!progress.value.containsKey(id)) return;
    final next = Map<String, double>.from(progress.value)..remove(id);
    progress.value = next;
  }

  void _bumpRevision() => revision.value = revision.value + 1;
}
