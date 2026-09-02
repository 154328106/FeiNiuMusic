import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../state/song_state.dart';
import '../feiniu/api_client.dart';
import '../netease/netease_api_client.dart';
import '../kugou/kugou_api_client.dart';
import '../qq/qq_api_client.dart';

class LyricsRepository {
  /// 加载歌词，优先从缓存读取，未命中则从 API 获取
  Future<String?> loadLrc(SongEntity song) async {
    // 1. 读取本地缓存
    final cached = await _readFromCache(song.id);
    if (cached != null && cached.trim().isNotEmpty) {
      return cached;
    }

    // 2. 从 API 获取。按来源分流 —— 之前这里一律问飞牛要歌词，网易云的歌
    //    拿 `ne:xxx` 这种 id 去问 NAS，必然什么都没有，表现就是「网易云的歌
    //    全都没歌词」。
    try {
      final lyricText = song.isNetease
          ? await _neteaseLrc(song)
          : song.isQQ
          ? await _qqLrc(song)
          : song.isKugou
          ? await _kugouLrc(song)
          : await FeiNiuApiClient.instance.getLyricText(song.id);
      if (lyricText != null && lyricText.trim().isNotEmpty) {
        await _writeToCache(song.id, lyricText);
        return lyricText;
      }
    } catch (_) {
      // API 返回失败时静默处理
    }

    return null;
  }

  /// 酷狗歌词。两步：按 hash 搜到 id + accesskey，再下载 base64 的 LRC。
  Future<String?> _kugouLrc(SongEntity song) async {
    final hash = song.kugouHash;
    if (hash == null) return null;
    return KugouApiClient.instance.lyric(
      hash,
      durationMs: song.durationMs ?? 0,
    );
  }

  /// QQ 音乐歌词。接口直接给明文 LRC（nobase64=1），不用再解码。
  Future<String?> _qqLrc(SongEntity song) async {
    final mid = song.qqMid;
    if (mid == null) return null;
    return QQApiClient.instance.lyric(mid);
  }

  /// 网易云歌词。有翻译就按「原文 / 译文」逐行合并成一份 LRC。
  ///
  /// 两边时间戳不一定一一对应，所以按时间标签归并：同一个标签下先原文、
  /// 后译文，解析器会把它们当成同一行的两段。
  Future<String?> _neteaseLrc(SongEntity song) async {
    final id = song.neteaseId;
    if (id == null) return null;
    final result = await NetEaseApiClient.instance.lyric(id);
    final lrc = result.lrc;
    if (lrc == null || lrc.trim().isEmpty) return null;
    final translated = result.translated;
    if (translated == null || translated.trim().isEmpty) return lrc;
    return _mergeTranslation(lrc, translated);
  }

  /// 把译文按时间标签并进原文。标签对不上的译文行直接丢掉，
  /// 宁可只有原文，也不要错位的翻译。
  static String _mergeTranslation(String lrc, String translated) {
    final tag = RegExp(r'^(\[\d{2}:\d{2}(?:[.:]\d{2,3})?\])(.*)$');
    final transByTag = <String, String>{};
    for (final line in translated.split('\n')) {
      final m = tag.firstMatch(line.trim());
      if (m == null) continue;
      final text = m.group(2)!.trim();
      if (text.isNotEmpty) transByTag[m.group(1)!] = text;
    }
    if (transByTag.isEmpty) return lrc;

    final out = <String>[];
    for (final line in lrc.split('\n')) {
      out.add(line);
      final m = tag.firstMatch(line.trim());
      if (m == null) continue;
      final t = transByTag[m.group(1)!];
      if (t != null) out.add('${m.group(1)!}$t');
    }
    return out.join('\n');
  }

  Future<void> removeCachedLrc(String songId) async {
    try {
      final file = await _cacheFileForSongId(songId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> saveLrcToCache(
    String songId,
    String content, {
    bool overwrite = false,
  }) async {
    final c = content.replaceFirst('﻿', '').trim();
    if (c.isEmpty) return;
    if (!overwrite) {
      final exists = await hasCachedLrc(songId);
      if (exists) return;
    }
    await _writeToCache(songId, c);
  }

  Future<bool> hasCachedLrc(String songId) async {
    try {
      final file = await _cacheFileForSongId(songId);
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> loadCachedLrc(String songId) async {
    return _readFromCache(songId);
  }

  Future<String?> _readFromCache(String songId) async {
    try {
      final file = await _cacheFileForSongId(songId);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToCache(String songId, String content) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final lyricsDir = Directory(p.join(dir.path, 'lyrics'));
      if (!await lyricsDir.exists()) {
        await lyricsDir.create(recursive: true);
      }
      final file = File(p.join(lyricsDir.path, '${_cacheKey(songId)}.lrc'));
      await file.writeAsString(content, flush: true);
    } catch (_) {}
  }

  Future<File> _cacheFileForSongId(String songId) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'lyrics', '${_cacheKey(songId)}.lrc'));
  }

  String _cacheKey(String songId) {
    final bytes = utf8.encode(songId);
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask64 = 0xFFFFFFFFFFFFFFFF;
    var hash = offsetBasis;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * prime) & mask64;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
