import 'package:flutter/foundation.dart';

import '../state/song_state.dart';
import 'download/download_service.dart';
import 'lxscript/lx_source_manager.dart';
import 'player_service.dart';

/// 在线歌的「音频规格」：实际拿到的文件是什么格式、多大、大概多少码率。
///
/// 网易以外的在线源把各自的 id 借放在 `SongEntity.audioSpec` 里（QQ 的
/// mediaMid、酷狗的 albumAudioId…），播放页「更多」原来直接把那串 id 当规格
/// 显示。这里改成看真正在播的文件：已下载的读本地文件头，在线的拉当前地址
/// 开头 64KB，显示成「FLAC · 32.4MB · 约 960kbps」。
class StreamSpec {
  StreamSpec._();

  /// 歌曲 id → 规格文字。同一首只探一次（地址换了音质也基本不变）。
  static final Map<String, String> _cache = {};

  static bool isOnline(SongEntity s) =>
      s.isNetease || s.isQQ || s.isKugou || s.isKuwo || s.isMigu;

  static Future<String?> describe(SongEntity song) async {
    final hit = _cache[song.id];
    if (hit != null) return hit;
    try {
      String? format;
      var size = 0;
      final local = DownloadService.instance.localFileFor(song.id);
      if (local != null) {
        size = await local.length();
        final raf = await local.open();
        final head = await raf.read(16);
        await raf.close();
        format = formatOf(head);
      } else {
        final url = await PlayerService.instance.onlineStreamUrlFor(song);
        if (url == null) return null;
        final probe = await LxSourceManager.probeAudio(url);
        if (probe.format == null) return null;
        format = probe.format;
        size = probe.size;
      }
      final text = compose(format, size, song.durationMs ?? 0);
      if (text != null) {
        if (_cache.length > 500) _cache.clear();
        _cache[song.id] = text;
      }
      return text;
    } catch (e) {
      debugPrint('[StreamSpec] ${song.id} 探测失败：$e');
      return null;
    }
  }

  /// 按文件头认格式。
  static String? formatOf(List<int> head) {
    bool at(String s, [int i = 0]) =>
        head.length >= i + s.length &&
        String.fromCharCodes(head.sublist(i, i + s.length)) == s;
    if (at('fLaC')) return 'FLAC';
    if (at('ftyp', 4)) return 'M4A';
    if (at('OggS')) return 'OGG';
    if (at('RIFF')) return 'WAV';
    if (at('ID3') || (head.length >= 2 && head[0] == 0xFF)) return 'MP3';
    return null;
  }

  /// 「FLAC · 32.4MB · 约 960kbps」；没有大小 / 时长就省掉那一段。
  @visibleForTesting
  static String? compose(String? format, int size, int durationMs) {
    if (format == null || format.isEmpty) return null;
    final parts = <String>[format];
    if (size > 0) parts.add('${(size / 1048576).toStringAsFixed(1)}MB');
    if (size > 0 && durationMs > 0) {
      final kbps = (size * 8 / durationMs).round(); // 字节×8 / 毫秒 = kbit/s
      parts.add('约 ${kbps}kbps');
    }
    return parts.join(' · ');
  }

  @visibleForTesting
  static void resetForTest() => _cache.clear();
}
