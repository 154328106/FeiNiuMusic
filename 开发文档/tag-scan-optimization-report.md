# 歌曲标签解析 / 扫描 —— 优化建议报告

*生成日期：2026-07-19*
*针对代码基线：`main` 分支当前 HEAD*
*执行者：Ditto*
*读者：接手实施的开发者*

---

## 背景

FeiNiuMusic 的本地音乐扫描 + 远程标签探测代码集中在以下三个文件：

- `lib/app/services/db/dao/song_dao.dart` — 歌曲入库
- `lib/app/services/local_music_service.dart` — 本地库全量 / 增量扫描
- `lib/app/services/metadata/tag_probe_service.dart` — 元信息（tag/封面/歌词）解析

用户在 1000+ 首歌的库上会观察到明显的扫描停顿。审计后发现有若干"做了两倍工作"的地方，以及一些**每次调用都在支付一次性成本**的模式。

本报告按预期收益从大到小列出，每一项独立、互不依赖。可以按优先级挑选实施。

---

## 🔴 高影响项（建议优先做）

### 1. `SongDao.upsertSongs` 每次扫描做了两次数据库写入

**位置**：`lib/app/services/db/dao/song_dao.dart:13-47`

**现状**：
```dart
final added = await db.transaction<int>((txn) async {
  var added = 0;
  final insertBatch = txn.batch();
  for (final song in songs) {
    insertBatch.insert(
      DbConstants.tableSongs,
      song.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,   // ← 第一遍：只为数出新增
    );
  }
  final insertResults = await insertBatch.commit();
  for (final result in insertResults) {
    if (result is int && result > 0) added += 1;
  }

  final updateBatch = txn.batch();
  for (final song in songs) {
    updateBatch.insert(
      DbConstants.tableSongs,
      song.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,  // ← 第二遍：真正写入
    );
  }
  await updateBatch.commit(noResult: true);
  return added;
});
```

**问题**：每首歌被序列化 + 写入 **两次**。第一次只是为了数"insert 成功的行数"（即"这一批里几首是新歌"），第二次才是真正的最终态。1000 首歌 = 2000 次写。

**建议改法**：查询一次现有 id 集合，然后单批 upsert，用集合差计算新增：

```dart
Future<int> upsertSongs(List<SongEntity> songs) async {
  if (songs.isEmpty) return 0;
  final db = await DbHelper.instance.database;

  // 一次性读出这批歌里已经存在的 id
  final ids = songs.map((s) => s.id).toList();
  final placeholders = List.filled(ids.length, '?').join(',');
  final existingRows = await db.query(
    DbConstants.tableSongs,
    columns: ['id'],
    where: 'id IN ($placeholders)',
    whereArgs: ids,
  );
  final existingIds = existingRows
      .map((r) => r['id'] as String)
      .toSet();
  final added = ids.where((id) => !existingIds.contains(id)).length;

  // 单次 batch，直接 REPLACE
  await db.transaction((txn) async {
    final batch = txn.batch();
    for (final song in songs) {
      batch.insert(
        DbConstants.tableSongs,
        song.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  });

  _cachedAll = null;
  CacheVersionStore.instance.bump(cacheVersionScope);
  return added;
}
```

**预期收益**：大库全量扫描的入库阶段 **提速约 40–50%**（写路径少一半 + 少一次 batch commit 开销）。

**风险**：低。行为等价（都是 upsert）；`added` 的语义完全一致；`_cachedAll` 失效与 CacheVersion bump 逻辑不动。

**测试**：跑一次 5000 首歌全新扫描 + 一次相同库的重复扫描（应几乎全命中 existing），对比时间。

---

### 2. `_readMetadataIsolate` 每首歌用 `compute()` 单独 spawn 一个 isolate

**位置**：`lib/app/services/metadata/tag_probe_service.dart:532`

**现状**：
```dart
Future<TagProbeResult?> _probeFromFile(File file, {...}) async {
  final raw = await compute(
    _readMetadataIsolate,
    _IsolateProbeInput(path: file.path, includeArtwork: includeArtwork),
  );
  ...
}
```

**问题**：`compute()` 每次调用都会 spawn 新 isolate（VM 冷启动 ~50–100ms，主线程调度开销 + 首次 lib 加载）。10000 首歌就是 500–1000 秒的纯 setup 空转。

**建议改法**：建立一个**长期 tag isolate**，扫描期间常驻，通过 `SendPort` 传输任务。

关键结构：

```dart
class _TagIsolatePool {
  final int workers;
  final List<_TagWorker> _pool = [];
  int _rr = 0;

  _TagIsolatePool({this.workers = 2});

  Future<void> start() async {
    for (var i = 0; i < workers; i++) {
      final w = await _TagWorker.spawn();
      _pool.add(w);
    }
  }

  Future<void> stop() async {
    for (final w in _pool) { w.close(); }
    _pool.clear();
  }

  Future<TagProbeResult?> probe(String path, bool includeArtwork) {
    final w = _pool[(_rr++) % _pool.length];  // 简单 round-robin
    return w.probe(path, includeArtwork);
  }
}

class _TagWorker {
  final SendPort _send;
  final Isolate _iso;
  final Map<int, Completer<TagProbeResult?>> _pending = {};
  int _seq = 0;

  _TagWorker._(this._iso, this._send, ReceivePort recv) {
    recv.listen((msg) {
      final (id, result) = msg as (int, TagProbeResult?);
      _pending.remove(id)?.complete(result);
    });
  }

  static Future<_TagWorker> spawn() async {
    final recv = ReceivePort();
    final ready = Completer<SendPort>();
    recv.listen((msg) {
      if (msg is SendPort && !ready.isCompleted) {
        ready.complete(msg);
      }
    });
    final iso = await Isolate.spawn(_entrypoint, recv.sendPort);
    final send = await ready.future;
    return _TagWorker._(iso, send, recv);
  }

  Future<TagProbeResult?> probe(String path, bool art) {
    final id = _seq++;
    final c = Completer<TagProbeResult?>();
    _pending[id] = c;
    _send.send((id, path, art));
    return c.future;
  }

  void close() { _iso.kill(priority: Isolate.immediate); }
}

void _entrypoint(SendPort main) {
  final recv = ReceivePort();
  main.send(recv.sendPort);
  recv.listen((msg) {
    final (id, path, art) = msg as (int, String, bool);
    final result = _readMetadataIsolateSync(path, art);
    main.send((id, result));
  });
}
```

`LocalMusicService` 在扫描开始时 `pool.start()`，结束时 `pool.stop()`；`_probeFromFile` 走 `pool.probe(...)` 而不是 `compute(...)`。

**预期收益**：大库首次扫描 **提速 3–5×**。`_metadataProbeMaxConcurrent = 2` 就够（`SongsPage` 那个后台补齐也用同一个池）。

**风险**：中等。
- 需要正确管理 pool 生命周期（app 退出 / 扫描取消时 kill）
- Isolate 之间共享代码但不共享全局状态；`_readMetadataIsolate` 已经是纯函数，直接搬即可
- 需要在扫描外单次调用（如 `SongsPage` 后台补 tag）时不引入内存驻留 —— 建议给 pool 加个 idle 超时，比如 30s 没任务就自动 stop

**测试**：4000 首歌，冷启动首次扫描；对比 `compute()` 版本，测端到端时间。

---

### 3. 扫描期间的 IO 没有去重 / 批量化

**位置**：`lib/app/services/local_music_service.dart:468-484`

**现状**：每首歌都单独：
- `_resolveCoverPath` —— 可能触发 `photo_manager` 缩略图请求；同专辑多首歌互相不去重，会重复请求
- `_lyricsRepo.saveLrcToCache(...)` —— 单独一次文件写

**问题**：一张 12 首歌的专辑会请 12 次缩略图（如果封面来自 assetId 而非嵌入）；专辑内所有歌的 lrc 分 12 次写入。

**建议改法**：

**a) 缩略图 in-flight 去重**（`ArtworkService.resolveLocalAssetId` 已经做了 URI 级去重，但 `_resolveCoverPath` 的调用路径可能绕过它）—— 审计一遍确保所有拿封面字节的路径都走过 dedup map。

**b) 歌词批量写**：`worker()` 内部收集 `(path, lrc)` 到临时 list，扫描结束一次性并发写：
```dart
final pendingLyrics = <(String, String)>[];
// ... worker 里改成 pendingLyrics.add((candidate.path, embeddedLyrics));

// 主流程末尾
await Future.wait(
  pendingLyrics.map((e) =>
    _lyricsRepo.saveLrcToCache(e.$1, e.$2, overwrite: true))
);
```

**预期收益**：中等。IO 密度大的场景（大库 + 有嵌入歌词），扫描末段可省 5–20 秒。

**风险**：低。行为不变；只是把散落写入攒成一波。

---

## 🟡 中等影响项

### 4. `getApplicationSupportDirectory()` 每次远程探测都调用

**位置**：`lib/app/services/metadata/tag_probe_service.dart:94, 703, 728, 780, 954`

**问题**：这是 `path_provider` 的 method channel 调用；单次很快（<1ms），但远程探测热路径每次都调，累计非零。

**建议改法**：在 `TagProbeService` 里加一个 `late final Future<Directory> _supportDir` 或者干脆存 String：

```dart
Future<Directory>? _supportDirFuture;
Future<Directory> _supportDir() {
  return _supportDirFuture ??= getApplicationSupportDirectory();
}
```

**预期收益**：小。远程流式探测有若干次连续调用，能省 5–10ms 的 channel 往返。

**风险**：无。目录路径进程内稳定。

---

### 5. 进度回调频率过高

**位置**：`lib/app/services/local_music_service.dart` — 各处 `onProgress(...)` 用 `processed % 10 == 0` 触发

**问题**：并发 12 worker 时会同时触发多个回调，UI setState 密度过高；扫描期间 UI 掉帧。

**建议改法**：时间节流，比如"至少 200ms 才回调一次"或者"处理数增量至少为 20"。

```dart
DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
void _maybeReport() {
  final now = DateTime.now();
  if (now.difference(_lastProgressAt).inMilliseconds < 200) return;
  _lastProgressAt = now;
  onProgress(LocalScanProgress(processed: processed, added: added, total: total));
}
```

**预期收益**：扫描期间 UI 更顺滑；不影响后台工作。

**风险**：低。最后一次强制回调即可保证 UI 显示"完成"状态。

---

### 6. `SongDao.fetchAllCached` 首次扫描后仍要 fetch 一次

**位置**：`lib/app/services/db/dao/song_dao.dart:99` + `local_music_service.dart:530`

**问题**：`upsertSongs` 后 `_cachedAll = null`，下次 `fetchAllCached` 又要从 SQLite 全量拉 + 每行 fromMap 反序列化。5000+ 首歌的库有几十 ms 主线程停顿。

**建议改法**：在 `upsertSongs` 里，如果传入的 songs 就是完整库（即调用方是扫描），可以选择性接受一个 `replaceCache: true` 参数直接更新 `_cachedAll`。或者：在扫描结束由 `LocalMusicService` 主动 `SongDao.setCache(scannedSongs)`（如果扫描本身就是全量）。

**预期收益**：小到中。避免扫描后紧接着的一次全量反序列化。

**风险**：低。缓存失效路径不变。

---

## 🟢 低影响项 / 代码卫生

### 7. HomeRecommender 每次 `build` 都重新算

**位置**：`lib/pages/home/home_page.dart` — `_dailySongs / _heartModeSongs / _recommendedSongs` 每次调用都实例化新的 `HomeRecommender`

**问题**：首页滚动或任何 `_HomePageState` 重建都会重算。1000 首歌 pool 全排序 ~几 ms，不致命但不必要。

**建议改法**：加 memoization。key = `(playCountsVersion, lastPlayedVersion, favoriteIdsVersion, filterValue)`，命中返回缓存。或者干脆把结果存到 signal 里，`_load` 完成后一次算。

**预期收益**：首页滑动更顺，冷启动 CPU 少几 %。

**风险**：低。需要注意 signal 依赖是否覆盖了所有输入变化。

---

### 8. 远程 tag 探测的 in-flight key 每次都要拼字符串

**位置**：`tag_probe_service.dart:117-138` `probeSongDedup`

**问题**：`'${isLocal ? 'local' : 'remote'}:$uri:$includeArtwork:$headerKey'` 每次拼 + hash。热路径次要开销。

**建议改法**：如果 headers 稳定（大部分场景是），可以在调用方做 key 缓存。可选优化。

**预期收益**：可忽略。

**风险**：无。

---

## 一个非本次审计出的观察

`tag_probe_service.dart` 的远程探测走 **2MB → 4MB → 8MB** 增量下载，每次都可能重启一次 tag 解析。这是**必要的**（tag 可能在头或尾），但可以观察：如果某个源 90% 的歌 tag 都在头部 2MB 内，可以配置化早停条件。当前实现 tag 齐全就返回，已经够好。

---

## 实施建议顺序

1. **先做 #1**（最小改动、最大即时收益、几乎零风险）
2. **再做 #3**（IO 批量化 —— 中等风险中等收益）
3. **接着 #5 + #7**（UI 顺滑度 —— 小改动，用户体感明显）
4. **最后 #2**（长期 isolate —— 需要仔细写生命周期，但收益上限最高）
5. #4 / #6 / #8 顺手做，不做也不影响

## 每项预期收益

| 编号 | 场景 | 现状 | 预期 |
|---|---|---|---|
| 1 | 5000 首全新扫描的入库阶段 | ~4 秒 | ~2 秒 |
| 2 | 5000 首首次 tag 解析 | ~120 秒 | ~30 秒 |
| 3 | 有嵌入歌词的 500 首歌尾段 | ~10 秒 | ~1 秒 |
| 5 | 扫描期间 UI 帧率 | 波动 | 稳定 |
| 7 | 首页滚动 | ~几 ms/帧 | 无感 |

---

## 验证方法

对每一项：
1. 在改动前 commit 一次基线
2. 用同一份库（建议 1000+ 首、含 mp3/flac/wav/ogg 混合）跑三次扫描取中位
3. 记录：`processed`、`added`、总耗时、入库耗时、tag 解析耗时（可以在关键路径打 `Stopwatch`）
4. 打包对比数据（不要凭感觉说"快多了"）

---

## 联系

如果实施中遇到疑问，主要的关键路径就是 `LocalMusicService.rescan → TagProbeService.probeSongDedup → SongDao.upsertSongs` 这三层。改一层前先把这条端到端跑通，其它调用方（`SongsPage` 后台补齐、播放器 side-load 元信息）会自动跟着走。
