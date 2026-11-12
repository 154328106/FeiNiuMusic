import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'player_engine.dart';

/// [PlayerEngine] 的 just_audio（ExoPlayer / MediaCodec）实现。
///
/// 薄封装：持有唯一的 just_audio [AudioPlayer]，把所有方法与流归一化转发。
///
/// `useProxyForRequestHeaders: false` 让 HLS/音频源的请求头（Cookie）由
/// Android ExoPlayer 原生发送（DefaultHttpDataSource），而不是走 just_audio
/// 的 Dart 本地代理（代理不解析 `#EXT-X-MAP`，且会用 Dart HttpClient 连 NAS
/// IPv6 导致不可达）。
class JustAudioEngine implements PlayerEngine {
  JustAudioEngine()
    : _player = AudioPlayer(
        useProxyForRequestHeaders: false,
        audioLoadConfiguration: _weakNetworkLoadConfig,
      );

  /// 弱网缓冲策略（2026-11-12 加；在此之前这里什么都没传，全用 just_audio 默认）。
  ///
  /// 弱网的核心是「网络好的那几秒尽量多囤」，而默认值囤得不够：
  /// - `maxBufferDuration` 50 → 120 秒：默认只提前囤 50 秒，地铁/电梯里一断就见底。
  /// - `prioritizeTimeOverSizeThresholds` false → true：**这条是关键**。为 false 时
  ///   ExoPlayer 会被内部字节上限提前截断，无损/高码率的歌实际远囤不到标称的
  ///   时长（1000kbps 的 FLAC 囤满 120 秒要 15MB）。开了才真按时间囤。
  /// - `backBufferDuration` 0 → 30 秒：默认播过就丢，往回拖一点点都要重新下载。
  ///
  /// 刻意不动的两个：`bufferForPlaybackDuration` 仍是 2.5 秒、
  /// `bufferForPlaybackAfterRebufferDuration` 仍是 5 秒 —— 它们是**起播门槛**，
  /// 调大会让「点下去到出声」变慢，和弱网优化的目标相反。囤得多和起播快不冲突。
  ///
  /// 代价：跳歌时已囤的最多约 120 秒白下；内存占用上升（受 ExoPlayer 自身的
  /// targetBufferBytes 兜底，没有显式放开）。
  static const _weakNetworkLoadConfig = AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      maxBufferDuration: Duration(seconds: 120),
      prioritizeTimeOverSizeThresholds: true,
      backBufferDuration: Duration(seconds: 30),
    ),
    darwinLoadControl: DarwinLoadControl(
      // iOS 的 automaticallyWaitsToMinimizeStalling 默认就是 true（AVPlayer 自己
      // 权衡起播与卡顿），保持不动；只把预读时长的建议值提到和 Android 一致。
      preferredForwardBufferDuration: Duration(seconds: 120),
    ),
  );

  final AudioPlayer _player;

  @override
  EngineKind get kind => EngineKind.justAudio;

  @override
  Future<void> init() async {
    // ExoPlayer 无需额外初始化；原生流由 PlayerService 订阅本引擎的转发流。
  }

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
  }) {
    final sources = items
        .cast<JustAudioItem>()
        .map((e) => e.source)
        .toList(growable: false);
    return _player.setAudioSources(
      sources,
      initialIndex: index,
      initialPosition: initialPosition,
      preload: preload,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> seekToNext() => _player.seekToNext();

  @override
  Future<void> seekToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToIndex(int index) =>
      _player.seek(Duration.zero, index: index);

  @override
  Future<void> setLoopMode(EngineLoopMode mode) {
    final loop = switch (mode) {
      EngineLoopMode.single => LoopMode.one,
      EngineLoopMode.all => LoopMode.all,
      EngineLoopMode.none => LoopMode.off,
    };
    return _player.setLoopMode(loop);
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> insertItem(int index, EngineItem item) =>
      _player.insertAudioSource(index, (item as JustAudioItem).source);

  @override
  Future<void> insertItems(int index, List<EngineItem> items) {
    final sources = items
        .cast<JustAudioItem>()
        .map((e) => e.source)
        .toList(growable: false);
    return _player.insertAudioSources(index, sources);
  }

  @override
  Future<void> removeItem(int index) => _player.removeAudioSourceAt(index);

  @override
  Future<void> moveItem(int from, int to) => _player.moveAudioSource(from, to);

  @override
  Duration get position => _player.position;

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  int get sequenceLength => _player.sequence.length;

  @override
  bool get hasLoadedSource => _player.audioSource != null;

  @override
  bool get playing => _player.playing;

  @override
  EngineProcessingState get processingState =>
      switch (_player.processingState) {
        ProcessingState.idle => EngineProcessingState.idle,
        ProcessingState.loading => EngineProcessingState.loading,
        ProcessingState.ready => EngineProcessingState.ready,
        ProcessingState.buffering => EngineProcessingState.buffering,
        ProcessingState.completed => EngineProcessingState.completed,
      };

  @override
  EngineLoopMode get loopMode => switch (_player.loopMode) {
    LoopMode.off => EngineLoopMode.none,
    LoopMode.one => EngineLoopMode.single,
    LoopMode.all => EngineLoopMode.all,
  };

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;

  @override
  Stream<EnginePlaybackState> get playbackStateStream =>
      _player.playerStateStream.map(
        (s) => EnginePlaybackState(
          playing: s.playing,
          processingState: switch (s.processingState) {
            ProcessingState.idle => EngineProcessingState.idle,
            ProcessingState.loading => EngineProcessingState.loading,
            ProcessingState.ready => EngineProcessingState.ready,
            ProcessingState.buffering => EngineProcessingState.buffering,
            ProcessingState.completed => EngineProcessingState.completed,
          },
        ),
      );

  @override
  Stream<EngineError> get errorStream => _player.errorStream.map(
    (e) => EngineError(message: e.message ?? '', index: e.index),
  );

  @override
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
}
