import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../state/settings_island_lyric.dart';
import '../services/feiniu/api_client.dart';
import '../services/lyrics/lyrics_service.dart';
import '../services/player_service.dart';

/// 通知歌词灵动岛服务。
///
/// 监听 [LyricsService.currentLineText] 与 [PlayerService]，在「开关打开、正在
/// 播放、当前行有歌词」时，通过 MethodChannel 驱动原生层发送 HyperOS/MIUI
/// 「焦点通知」，让歌词渲染在系统灵动岛。暂停/停止/无歌词时隐藏。
///
/// 更新策略：
/// - 歌词行变化 → 立即发送（[shouldUpdate] 去重相同行）；
/// - 播放进度变化 → 节流发送（[_progressThrottle]，避免频繁刷新系统通知）。
///
/// 测试模式（[IslandLyricSettings.testMode]）：打开后即使不播放也持续模拟发送，
/// 用于验证暂停/无播放时灵动岛是否仍能渲染。
class IslandLyricService {
  IslandLyricService._();

  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/island_lyric',
  );

  /// 跳转到 MIUI/HyperOS 息屏通知动画设置页（供「息屏歌词」提示使用）。
  /// 无 root 时通过显式 Intent 启动；目标组件不存在 / 未导出时返回 false。
  static Future<bool> openAodSettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openAodSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 当前设备是否 HyperOS/MIUI（用于「息屏通知设置」跳转行仅在 HyperOS 显示）。
  ///
  /// 判定：MIUI 系统包 [com.miui.aod] 存在即视为小米 HyperOS 系设备。
  /// 结果缓存（跨次调用不变），调用失败按非 HyperOS 处理。
  static bool? _isHyperOs;
  static Future<bool> isHyperOs() async {
    if (_isHyperOs != null) return _isHyperOs!;
    try {
      final ok = await _channel.invokeMethod<bool>('isHyperOs');
      _isHyperOs = ok ?? false;
    } catch (_) {
      _isHyperOs = false;
    }
    return _isHyperOs!;
  }

  /// 测试专用：清空 HyperOS 探测缓存，供测试重复探测。
  @visibleForTesting
  static void resetDeviceProbeForTest() {
    _isHyperOs = null;
  }

  /// 进度更新节流：同一首歌内，两次进度驱动发送的最小间隔。
  static const Duration _progressThrottle = Duration(milliseconds: 500);

  /// 测试模式模拟发送间隔。
  static const Duration _testModeInterval = Duration(milliseconds: 800);

  /// 每帧最大字符数（最多一次显示 10 个字）：超过该长度智能截断拆帧，
  /// 避免焦点通知单侧文本被系统中间截断。每帧再对半分配到左右两侧。
  static const int _frameChars = 10;

  static bool _started = false;
  static String? _lastLyricLine;
  static bool _lastIsPlaying = false;
  static DateTime? _lastProgressSent;
  static Timer? _testModeTimer;
  static int _testTick = 0;
  static int _lastFrameIndex = 0;

  // 封面相关状态
  static String? _lastSongId;
  static String? _lastCoverId;
  static String? _lastCoverPath;

  /// 封面本地缓存目录
  static String? _coverDirPath;
  static final DefaultCacheManager _coverCache = DefaultCacheManager();

  /// 幂等启动。默认监听 [LyricsService.instance] 与 [PlayerService.instance]。
  static void start() {
    if (_started) return;
    _started = true;
    IslandLyricSettings.enabled.addListener(_onSettingsChanged);
    IslandLyricSettings.testMode.addListener(_onSettingsChanged);
    IslandLyricSettings.aodLyrics.addListener(_onSettingsChanged);
    LyricsService.instance.currentLineText.addListener(_onLyricLineChanged);
    PlayerService.instance.isPlaying.addListener(_onPlayingChanged);
    PlayerService.instance.position.addListener(_onPositionChanged);
    _syncTestMode();
    _syncLyric();
  }

  /// 测试专用：停止监听并复位。
  @visibleForTesting
  static void resetForTest() {
    if (!_started) return;
    IslandLyricSettings.enabled.removeListener(_onSettingsChanged);
    IslandLyricSettings.testMode.removeListener(_onSettingsChanged);
    IslandLyricSettings.aodLyrics.removeListener(_onSettingsChanged);
    LyricsService.instance.currentLineText.removeListener(_onLyricLineChanged);
    PlayerService.instance.isPlaying.removeListener(_onPlayingChanged);
    PlayerService.instance.position.removeListener(_onPositionChanged);
    _started = false;
    _stopTestTimer();
    _lastLyricLine = null;
    _lastIsPlaying = false;
    _lastProgressSent = null;
    _lastFrameIndex = 0;
    _lastSongId = null;
    _lastCoverId = null;
    _lastCoverPath = null;
  }

  /// 核心决策：是否应向灵动岛推送歌词。
  @visibleForTesting
  static bool shouldShow({
    required bool enabled,
    required bool isPlaying,
    required String? lyricLine,
  }) {
    if (!enabled) return false;
    if (!isPlaying) return false;
    if (lyricLine == null || lyricLine.trim().isEmpty) return false;
    return true;
  }

  /// 歌词行是否值得更新（去重）：上一行与当前行不同则更新。
  @visibleForTesting
  static bool shouldUpdate({required String? previous, required String? next}) {
    if (next == null || next.trim().isEmpty) return false;
    return previous != next;
  }

  /// 测试模式：生成一条模拟歌词通知的 payload（纯函数，确定性）。
  ///
  /// - 歌词行在 [lyricCount] 行内循环（`测试歌词 1/4` ... `测试歌词 4/4`）；
  /// - 进度随 tick 递增，到 100 归零循环；
  /// - 始终 [isPlaying]=true，模拟「暂停/不播放」下仍在上岛。
  @visibleForTesting
  static Map<String, Object> simulateTestPayload({
    required int tick,
    required int lyricCount,
  }) {
    final lineIndex = tick % lyricCount;
    // 进度随 tick 递增：每行歌词推进 100/lyricCount 个百分点，到顶后归零循环
    final step = (100 / lyricCount).round();
    final progress = ((tick % 100) * step) % 100;
    final lyric = '测试歌词 ${lineIndex + 1}/$lyricCount';
    final split = splitLyricForIsland(lyric);
    return {
      'lyric': split.right,
      'leftLyric': split.left,
      'title': '灵动岛测试',
      'artist': 'FeiNiu Music',
      'isPlaying': true,
      'progress': progress,
      'positionMs': progress * 1000, // 模拟进度对应位置
      'durationMs': 100000, // 100s
      'showProgress': true,
    };
  }

  // ---- 测试模式 ----

  static void _onSettingsChanged() {
    _syncTestMode();
    _syncLyric();
  }

  static void _syncTestMode() {
    final testMode = IslandLyricSettings.testMode.value;
    if (testMode) {
      _startTestTimer();
    } else {
      _stopTestTimer();
    }
  }

  static void _startTestTimer() {
    if (_testModeTimer != null) return;
    _testModeTimer = Timer.periodic(_testModeInterval, (_) {
      final payload = simulateTestPayload(tick: _testTick++, lyricCount: 4);
      _lastLyricLine = payload['lyric'] as String;
      _lastIsPlaying = true;
      _channel.invokeMethod('update', payload);
    });
  }

  static void _stopTestTimer() {
    _testModeTimer?.cancel();
    _testModeTimer = null;
    _testTick = 0;
    if (_lastLyricLine != null || _lastIsPlaying) {
      _lastLyricLine = null;
      _lastIsPlaying = false;
      _channel.invokeMethod('hide');
    }
  }

  // ---- 大岛歌词分割 ----

  /// 分割结果：左侧放前半段，右侧放后半段，拼接成完整歌词。
  ///
  /// 优先在空格/词边界分割（避免把短语从中间切开），两侧均去掉首尾空格，
  /// 防止尾随空格导致系统侧滚动/错位。无空格时按字符数均分。
  @visibleForTesting
  static ({String left, String right}) splitLyricForIsland(String lyric) {
    final trimmed = lyric.trim();
    if (trimmed.isEmpty) return (left: '', right: '');
    final chars = trimmed.runes.toList();

    // 优先在空格处断：找中间段里最近的空格，避免切开短语
    var cut = (chars.length / 2).ceil();
    // 在 [cut/2, cut] 区间内找最后一个空格，使两侧更均衡
    for (var j = cut; j > 0; j--) {
      if (chars[j - 1] == 0x20) {
        cut = j;
        break;
      }
    }
    // 找不到空格则按字符均分
    if (cut <= 0 || cut >= chars.length) {
      cut = (chars.length / 2).ceil();
    }

    final left = String.fromCharCodes(chars.take(cut)).trim();
    final right = String.fromCharCodes(chars.skip(cut)).trim();
    // 若右侧为空但左侧有值（极端情况），把整行放右侧
    if (right.isEmpty && left.isNotEmpty) {
      return (left: '', right: trimmed);
    }
    return (left: left, right: right);
  }

  /// 是否应发送/更新封面（纯函数）。
  ///
  /// 仅在切歌或封面 id 变化时返回 true，避免同一首歌反复下载封面。
  /// 无封面 id 的歌曲恒返回 false（不发封面）。
  @visibleForTesting
  static bool shouldSendCover({
    required String? prevSongId,
    required String? prevCoverId,
    required String? newSongId,
    required String? newCoverId,
  }) {
    if (newCoverId == null || newCoverId.isEmpty) return false;
    if (prevSongId == newSongId && prevCoverId == newCoverId) return false;
    return true;
  }

  /// 超长歌词智能拆帧（纯函数）。
  ///
  /// 按 [frameChars] 字符数拆帧，每帧不超过该容量。优先在空格/词边界断，
  /// 避免把中文短语或短英文单词从中间切开；单个超长 ASCII 单词本身必须被切
  /// 时仍切成多帧（每帧不超容量）。短歌词单帧，空歌词无帧。所有帧拼接 =
  /// 完整歌词（无丢失）。
  ///
  /// 用途：焦点通知单侧文本超宽会被系统中间截断（隐藏中间字），拆帧后每帧
  /// 用满左右两侧、按行节奏切换，避免截断。
  @visibleForTesting
  static List<String> chunkLyric(String lyric, {required int frameChars}) {
    if (lyric.isEmpty) return const [];
    final chars = lyric.runes.toList();
    if (chars.length <= frameChars) return [lyric.trim()];

    final frames = <String>[];
    var i = 0;
    while (i < chars.length) {
      var end = (i + frameChars).clamp(0, chars.length);
      // 智能断点：优先在最近的空格/词边界断，避免把词从中间切开
      if (end < chars.length) {
        var boundary = -1;
        for (var j = end; j > i; j--) {
          if (chars[j - 1] == 0x20) {
            boundary = j;
            break;
          }
        }
        if (boundary > i && boundary < end) {
          end = boundary;
        }
      }
      // 跳过段首空格（空格作为分隔符，不留在帧首）
      var start = i;
      while (start < end && chars[start] == 0x20) {
        start++;
      }
      // 跳过段尾空格（不留在帧尾，避免系统侧滚动/错位）
      while (end > start && chars[end - 1] == 0x20) {
        end--;
      }

      if (end > start) {
        frames.add(String.fromCharCodes(chars.sublist(start, end)));
      }
      i = end > i ? end : i + 1;
    }
    return frames;
  }

  /// 当前播放位置对应的帧索引（纯函数）。
  ///
  /// 在行时间窗口 [start, end] 内按 [frameCount] 等分，位置落在哪一段就返回
  /// 哪一帧；位置在行开始前返回 0，行结束后返回最后一帧。[lineEndMs] 为 null
  /// 或 [frameCount]≤1 时恒返回 0。
  @visibleForTesting
  static int frameIndexForPosition({
    required int frameCount,
    required int lineStartMs,
    required int? lineEndMs,
    required int positionMs,
  }) {
    if (lineEndMs == null || frameCount <= 1) return 0;
    if (positionMs <= lineStartMs) return 0;
    if (positionMs >= lineEndMs) return frameCount - 1;
    final window = lineEndMs - lineStartMs;
    final ratio = (positionMs - lineStartMs) / window;
    final index = (ratio * frameCount).floor();
    return index.clamp(0, frameCount - 1);
  }

  // ---- 监听回调 ----

  static void _onLyricLineChanged() => _syncLyric();
  static void _onPlayingChanged() => _syncLyric();

  static void _onPositionChanged() {
    final enabled = IslandLyricSettings.enabled.value;
    if (!enabled) return;
    final isPlaying = PlayerService.instance.isPlaying.value;
    final lyricLine = LyricsService.instance.currentLineText.value;
    if (!shouldShow(enabled: true, isPlaying: isPlaying, lyricLine: lyricLine)) {
      return;
    }
    if (_lastLyricLine == null) return; // 当前未在显示，无需刷进度

    // 超长歌词：检测拆帧翻转（帧推进），翻转时立即重发
    final frames = chunkLyric(_lastLyricLine!, frameChars: _frameChars);
    if (frames.length > 1) {
      final (startMs, endMs) = _currentLineWindow();
      final frame = frameIndexForPosition(
        frameCount: frames.length,
        lineStartMs: startMs,
        lineEndMs: endMs,
        positionMs: PlayerService.instance.position.value.inMilliseconds,
      );
      if (frame != _lastFrameIndex) {
        _lastFrameIndex = frame;
        _sendUpdate();
        return;
      }
    }

    final now = DateTime.now();
    if (_lastProgressSent != null &&
        now.difference(_lastProgressSent!) < _progressThrottle) {
      return;
    }
    _lastProgressSent = now;
    _sendUpdate();
  }

  /// 汇总当前状态并驱动原生层（歌词行 / 播放状态 / 开关变化时调用）。
  static void _syncLyric() {
    final enabled = IslandLyricSettings.enabled.value;
    final isPlaying = PlayerService.instance.isPlaying.value;
    final lyricLine = LyricsService.instance.currentLineText.value;

    if (!shouldShow(
      enabled: enabled,
      isPlaying: isPlaying,
      lyricLine: lyricLine,
    )) {
      if (_lastLyricLine != null || _lastIsPlaying) {
        _lastLyricLine = null;
        _lastIsPlaying = false;
        _lastProgressSent = null;
        _lastFrameIndex = 0;
        _channel.invokeMethod('hide');
      }
      return;
    }

    if (shouldUpdate(previous: _lastLyricLine, next: lyricLine)) {
      _lastLyricLine = lyricLine;
      _lastIsPlaying = isPlaying;
      _lastFrameIndex = 0;
      _sendUpdate();
      _maybeDownloadCover();
    }
  }

  /// 封面变化时异步下载封面到本地文件，下载完成后随下次 update 发送。
  static Future<void> _maybeDownloadCover() async {
    final song = PlayerService.instance.currentSong.value;
    final coverId = song?.coverId;
    if (!shouldSendCover(
      prevSongId: _lastSongId,
      prevCoverId: _lastCoverId,
      newSongId: song?.id,
      newCoverId: coverId,
    )) {
      return;
    }
    _lastSongId = song?.id;
    _lastCoverId = coverId;
    _lastCoverPath = null;

    if (coverId == null || coverId.isEmpty) return;

    final path = await _downloadCoverLocal(coverId, updatedAt: song?.updatedAt);
    if (path == null) return;
    _lastCoverPath = path;
    // 封面就绪后补发一次 update（带 coverPath），让原生层刷新左侧封面
    if (_started && _lastLyricLine != null) {
      _sendUpdate();
    }
  }

  static Future<String?> _downloadCoverLocal(
    String coverId, {
    int? updatedAt,
  }) async {
    final url = FeiNiuApiClient.instance.coverUrl(
      coverId, size: 120, updatedAt: updatedAt,
    );
    // 1. 先查缓存
    try {
      final cacheObject = await _coverCache.getFileFromCache(url);
      if (cacheObject != null) {
        final cachedPath = cacheObject.file.path;
        final cachedFile = io.File(cachedPath);
        if (await cachedFile.exists()) return cachedPath;
      }
    } catch (_) {}
    // 2. 下载到缓存
    try {
      final cacheFile = await _coverCache.getSingleFile(
        url,
        headers: FeiNiuApiClient.imageAuthHeaders(),
      );
      final localFile = io.File(cacheFile.path);
      if (await localFile.exists()) return cacheFile.path;
    } catch (_) {}
    // 3. fallback 下载到独立目录（自签名证书兼容）
    try {
      final dir = await _coverDir();
      final suffix = (updatedAt != null && updatedAt > 0) ? '_$updatedAt' : '';
      final filePath = '$dir/${coverId}_120$suffix.jpg';
      final file = io.File(filePath);
      if (await file.exists()) return filePath;
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
          await file.writeAsBytes(bytes);
          return filePath;
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (_) {}
    return null;
  }

  static Future<String> _coverDir() async {
    if (_coverDirPath == null) {
      final dir = await getTemporaryDirectory();
      _coverDirPath = '${dir.path}/island_covers';
      await io.Directory(_coverDirPath!).create(recursive: true);
    }
    return _coverDirPath!;
  }

  /// 向原生层发送完整当前状态（歌词 + 歌曲信息 + 播放进度）。
  ///
  /// 歌词展示：拆帧后每帧对半分配到左右两侧（leftLyric = 帧前半、lyric = 帧后半）。
  /// 短歌词单帧（整行）；超长歌词按行节奏推进帧（[_lastFrameIndex] 由位置监听
  /// 更新），每帧用满左右两侧且每侧不超系统容量 → 避免单侧文本被系统中间截断。
  static void _sendUpdate() {
    final player = PlayerService.instance;
    final song = player.currentSong.value;
    final lyricLine = _lastLyricLine;
    if (lyricLine == null) return;

    final frames = chunkLyric(lyricLine, frameChars: _frameChars);
    // 帧索引：单帧恒 0；多帧取当前已计算的帧（位置监听负责推进 _lastFrameIndex）
    final frameIndex = frames.length <= 1
        ? 0
        : _lastFrameIndex.clamp(0, frames.length - 1);
    final frame = frames[frameIndex];
    final split = splitLyricForIsland(frame);

    final payload = buildUpdatePayload(
      fullLyric: frame,
      title: song?.title ?? '',
      artist: song?.artistDisplayName ?? '',
      isPlaying: player.isPlaying.value,
      positionMs: player.position.value.inMilliseconds,
      durationMs: song?.durationMs ?? 0,
      showProgress: IslandLyricSettings.showProgress.value,
      coverPath: _lastCoverPath,
      aodLyrics: IslandLyricSettings.aodLyrics.value,
    );
    // 左右分割后的实际显示内容（覆盖 payload 里由 fullLyric 派生的 lyric/leftLyric）
    payload['lyric'] = split.right;
    payload['leftLyric'] = split.left;

    _channel.invokeMethod('update', payload);
  }

  /// 构建发送给原生层的 update payload（纯函数，可测）。
  ///
  /// [fullLyric] = 完整当前歌词帧（供息屏 aodTitle / 通知标题使用）。
  /// 返回的 map 含 lyric/leftLyric，但由调用方按 split 结果覆盖为左右半。
  @visibleForTesting
  static Map<String, Object?> buildUpdatePayload({
    required String fullLyric,
    required String title,
    required String artist,
    required bool isPlaying,
    required int positionMs,
    required int durationMs,
    required bool showProgress,
    required String? coverPath,
    required bool aodLyrics,
  }) {
    final split = splitLyricForIsland(fullLyric);
    return {
      'fullLyric': fullLyric,
      'lyric': split.right,
      'leftLyric': split.left,
      'title': title,
      'artist': artist,
      'isPlaying': isPlaying,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'showProgress': showProgress,
      'coverPath': coverPath,
      'aodLyrics': aodLyrics,
    };
  }
  /// 当前歌词行的时间窗口 [start, end]，毫秒。无歌词模型时返回兜底（start=0）。
  static (int, int?) _currentLineWindow() {
    final model = LyricsService.instance.snapshot.value.model;
    final index = LyricsService.instance.controller.activeIndexNotifiter.value;
    if (model == null || index < 0 || index >= model.lines.length) {
      return (0, null);
    }
    final line = model.lines[index];
    return (
      line.start.inMilliseconds,
      line.end?.inMilliseconds,
    );
  }
}
