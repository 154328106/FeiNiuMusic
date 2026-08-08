import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import '../../state/settings_cast_state.dart';
import '../../state/song_state.dart';
import '../feiniu/api_client.dart';
import '../feiniu/transcode_service.dart';
import 'media_stream_proxy.dart';

/// DLNA 投屏状态。
enum DlnaCastState {
  /// 未投屏、未在搜索。
  idle,

  /// 正在搜索局域网设备。
  discovering,

  /// 已连接设备并投屏中（遥控模式）。
  casting,
}

/// DLNA 投屏服务（单例）。基于 [media_cast_dlna]（jUPnP）。
///
/// 职责：
/// - **发现**：SSDP 搜索局域网 DLNA 渲染器，维护设备列表与状态；
/// - **投屏**：把当前歌曲的音频流经 [MediaStreamProxy] 换签为匿名 URL 后
///   推送到目标设备（`setMediaUri` + `play`）；
/// - **遥控**：投屏期间 play/pause/seek/setVolume 转发到投屏设备；
/// - **断开**：停止投屏、停代理，回调让 [PlayerService] 恢复本机续播。
///
/// 音频流 Cookie 认证问题：飞牛流地址要 `Cookie: music-token`，渲染器发不了，
/// 故经本地代理注入认证头；无损/高码率格式优先走服务器转码的 MP3 HLS，
/// 保证渲染器可解码（详见 [MediaStreamProxy] 与 [FeiNiuTranscodeService]）。
class DlnaCastService {
  DlnaCastService._();

  static final DlnaCastService instance = DlnaCastService._();

  final MediaCastDlnaApi _api = MediaCastDlnaApi();

  MediaCastDlnaDiscoveryEvents? _events;

  /// 最近一次发现的设备快照（按 UDN 去重）。
  final ValueNotifier<List<DlnaDevice>> devices = ValueNotifier(const []);

  /// 投屏状态（idle / discovering / casting）。
  final ValueNotifier<DlnaCastState> state =
      ValueNotifier(DlnaCastState.idle);

  /// 当前投屏目标设备。
  final ValueNotifier<DlnaDevice?> currentDevice = ValueNotifier(null);

  /// 投屏后由 [PlayerService] 注册：开始投屏时暂停本机、断开时恢复本机。
  void Function()? onCastStart;
  void Function()? onCastDisconnect;

  /// 投屏位置/状态轮询回调（由 [PlayerService] 注册，把投屏设备进度同步到
  /// 播放页 UI）。参数为（position, playing）。
  void Function(Duration position, bool playing)? onCastProgress;

  /// 投屏会话是否已建立。以「已连接设备」为准，不依赖 [state]——
  /// 投屏期间打开面板搜索其他设备会把 state 切到 discovering，但投屏会话
  /// 仍在继续，遥控逻辑必须保持生效。
  bool get isCasting => currentDevice.value != null;

  /// 是否正在发现设备。
  bool get isDiscovering => state.value == DlnaCastState.discovering;

  /// 设备列表（只读视图，供 UI 直接使用）。
  List<DlnaDevice> get knownDevices => devices.value;

  /// 投屏设备的播放位置（秒），供播放页进度条展示；投屏期间周期轮询。
  final ValueNotifier<Duration> castPosition = ValueNotifier(Duration.zero);

  /// 投屏设备的播放/暂停状态（供 UI 展示，不同于本机引擎状态）。
  final ValueNotifier<bool> castPlaying = ValueNotifier(false);

  Timer? _positionPollTimer;

  StreamSubscription<DlnaDevice>? _foundSub;
  StreamSubscription<DeviceUdn>? _lostSub;
  StreamSubscription<DeviceUdn>? _offlineSub;
  bool _serviceInitialized = false;
  Future<void>? _initFuture;

  /// 初始化 jUPnP 服务（幂等）。失败时置 false 让下次重试。
  Future<void> _ensureInitialized() async {
    if (_serviceInitialized) return;
    final init = _initFuture ??= _doInit();
    try {
      await init;
    } finally {
      // 允许失败后重试
    }
  }

  Future<void> _doInit() async {
    try {
      await _api.initializeUpnpService();
      _serviceInitialized = true;
      _initFuture = null;
      if (kDebugMode) debugPrint('[DlnaCastService] UPnP initialized');
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] UPnP init failed: $e');
      _serviceInitialized = false;
      _initFuture = null;
      rethrow;
    }
  }

  /// 订阅发现事件流（幂等）。首次调用时创建事件接收器。
  void _ensureEvents() {
    if (_events != null) return;
    final events = MediaCastDlnaDiscoveryEvents();
    _events = events;
    _foundSub = events.onDeviceFound.listen(_handleDeviceFound);
    _lostSub = events.onDeviceLost.listen(_handleDeviceLost);
    _offlineSub = events.onRendererOffline.listen(_handleRendererOffline);
  }

  /// 释放事件订阅与投屏会话（应用退出时调用）。
  Future<void> dispose() async {
    await disconnect(reason: null);
    _foundSub?.cancel();
    _lostSub?.cancel();
    _offlineSub?.cancel();
    _foundSub = null;
    _lostSub = null;
    _offlineSub = null;
    try {
      await _events?.dispose();
    } catch (_) {}
    _events = null;
    try {
      await _api.shutdownUpnpService();
    } catch (_) {}
  }

  void _handleDeviceFound(DlnaDevice device) {
    final list = List<DlnaDevice>.from(devices.value);
    final existing = list.indexWhere((d) => d.udn.value == device.udn.value);
    if (existing >= 0) {
      list[existing] = device;
    } else {
      list.add(device);
    }
    devices.value = List.unmodifiable(list);
  }

  void _handleDeviceLost(DeviceUdn udn) {
    final list = List<DlnaDevice>.from(devices.value)
      ..removeWhere((d) => d.udn.value == udn.value);
    devices.value = List.unmodifiable(list);
  }

  void _handleRendererOffline(DeviceUdn udn) {
    // 当前投屏设备掉线 → 自动断开并恢复本机
    final current = currentDevice.value;
    if (current != null && current.udn.value == udn.value) {
      unawaited(disconnect(reason: '投屏设备已离线'));
    }
  }

  /// 开始搜索局域网 DLNA 设备。总开关关闭时直接返回。
  Future<void> startDiscovery() async {
    if (!DlnaCastSettings.enabled.value) return;
    if (isDiscovering) return;
    try {
      await _ensureInitialized();
      _ensureEvents();
      state.value = DlnaCastState.discovering;
      await _api.startDiscovery(
        DiscoveryOptions(
          searchTarget: SearchTarget(
            target: 'urn:schemas-upnp-org:device:MediaRenderer:1',
          ),
          timeout: DiscoveryTimeout(seconds: 5),
        ),
      );
      if (kDebugMode) {
        debugPrint('[DlnaCastService] discovery started');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DlnaCastService] startDiscovery failed: $e');
      }
      state.value = DlnaCastState.idle;
    }
  }

  /// 停止搜索（不中断已建立的投屏会话）。
  Future<void> stopDiscovery() async {
    if (state.value == DlnaCastState.idle) return;
    try {
      await _api.stopDiscovery();
    } catch (_) {}
    if (state.value == DlnaCastState.discovering) {
      state.value = DlnaCastState.idle;
    }
  }

  /// 选择一台设备并投屏当前歌曲。
  ///
  /// 若已在投屏则先断开旧设备（静默：不触发本机恢复，避免切设备时
  /// 本机短暂出声）。播放 URL 解析规则：
  /// - 需转码 / media_kit 专属格式（DSF/APE/WMA/FLAC 帧超限…）→ 优先转码 MP3
  ///   HLS（渲染器可解码）；失败退直连；
  /// - 其余（MP3/AAC/…）→ 直连流。
  /// 统一经 [MediaStreamProxy] 换签为匿名 URL。
  Future<bool> castTo(
    DlnaDevice device,
    SongEntity song,
  ) async {
    if (!DlnaCastSettings.enabled.value) return false;
    try {
      await _ensureInitialized();
      if (currentDevice.value != null) {
        await disconnect(reason: null, silent: true);
      }
      final proxyUrl = await _resolveCastUrl(song);
      if (proxyUrl == null) {
        if (kDebugMode) {
          debugPrint('[DlnaCastService] no castable url for ${song.title}');
        }
        return false;
      }

      final metadata = AudioMetadata(
        title: song.title.trim().isEmpty ? '未知歌曲' : song.title.trim(),
        artist: song.artistDisplayName.trim().isEmpty
            ? null
            : song.artistDisplayName.trim(),
        album: song.albumDisplayName.trim().isEmpty
            ? null
            : song.albumDisplayName.trim(),
        duration: song.durationMs != null && song.durationMs! > 0
            ? TimeDuration(seconds: (song.durationMs! / 1000).round())
            : null,
      );

      await _api.setMediaUri(
        device.udn,
        Url(value: proxyUrl),
        metadata,
      );
      await _api.play(device.udn);

      currentDevice.value = device;
      state.value = DlnaCastState.casting;
      castPosition.value = Duration.zero;
      castPlaying.value = true;
      _startPositionPoll();
      onCastStart?.call();
      if (kDebugMode) {
        debugPrint('[DlnaCastService] cast ${song.title} -> ${device.friendlyName}');
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] castTo failed: $e');
      return false;
    }
  }

  /// 解析可投屏的音频地址（转码 MP3 HLS 优先 / 直连兜底），经代理换签。
  Future<String?> _resolveCastUrl(SongEntity song) async {
    // 1) 需转码（DSF/APE/WMA… 或超过阈值的大文件）→ 转码 MP3 HLS
    //    （渲染器通用性最好）。失败则回退直连。
    final needsTranscode =
        FeiNiuTranscodeService.isMediaKitFormat(song.format ?? '') ||
        await FeiNiuTranscodeService.instance.shouldTranscode(song);
    if (needsTranscode) {
      final hls = await FeiNiuTranscodeService.instance.transcodeMp3UrlFor(
        song,
      );
      if (hls != null) {
        return MediaStreamProxy.instance.registerMedia(
          hls,
          headers: FeiNiuApiClient.imageAuthHeaders(),
        );
      }
    }

    // 2) 直连流兜底。
    final stream = FeiNiuApiClient.instance.streamUrl(song.id);
    return MediaStreamProxy.instance.registerMedia(
      stream,
      headers: FeiNiuApiClient.imageAuthHeaders(),
    );
  }

  // ---- 遥控 ----

  Future<void> play() async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.play(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] play failed: $e');
    }
  }

  Future<void> pause() async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.pause(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] pause failed: $e');
    }
  }

  Future<void> stop() async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.stop(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] stop failed: $e');
    }
  }

  Future<void> seek(Duration position) async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.seek(
        device.udn,
        TimePosition(seconds: position.inSeconds),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] seek failed: $e');
    }
  }

  /// 设置投屏设备音量（0.0–1.0）。
  Future<void> setVolume(double volume) async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.setVolume(
        device.udn,
        VolumeLevel(percentage: (volume.clamp(0.0, 1.0) * 100).round()),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] setVolume failed: $e');
    }
  }

  /// 在投屏设备上切换歌曲（换一条媒体流继续播）。
  Future<void> loadSong(SongEntity song) async {
    final device = currentDevice.value;
    if (device == null) return;
    final proxyUrl = await _resolveCastUrl(song);
    if (proxyUrl == null) return;
    try {
      await _api.setMediaUri(
        device.udn,
        Url(value: proxyUrl),
        AudioMetadata(
          title: song.title.trim().isEmpty ? '未知歌曲' : song.title.trim(),
          artist: song.artistDisplayName.trim().isEmpty
              ? null
              : song.artistDisplayName.trim(),
        ),
      );
      await _api.play(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] loadSong failed: $e');
    }
  }

  /// 断开投屏：停止设备播放、停代理、恢复本机播放。
  ///
  /// [reason] 非空时向 UI 提示（设备离线等）。[silent] 为 true 时不触发
  /// `onCastDisconnect`（切换投屏设备时用，避免本机短暂恢复出声）。
  Future<void> disconnect({String? reason, bool silent = false}) async {
    final wasCasting = isCasting;
    await stopDiscovery();
    _stopPositionPoll();
    castPosition.value = Duration.zero;
    castPlaying.value = false;
    try {
      await stop();
    } catch (_) {}
    currentDevice.value = null;
    state.value = DlnaCastState.idle;
    MediaStreamProxy.instance.stop();
    if (wasCasting && !silent) {
      onCastDisconnect?.call();
      if (reason != null && kDebugMode) {
        debugPrint('[DlnaCastService] disconnected: $reason');
      }
    }
  }

  /// 投屏期间周期轮询设备播放位置与状态，驱动播放页进度条。
  void _startPositionPoll() {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final device = currentDevice.value;
      if (device == null) return;
      try {
        final info = await _api.getPlaybackInfo(device.udn);
        if (currentDevice.value == null) return; // 已断开
        castPosition.value = Duration(seconds: info.position.seconds);
        switch (info.state) {
          case TransportState.playing:
            castPlaying.value = true;
          case TransportState.paused:
            castPlaying.value = false;
          case TransportState.stopped:
          case TransportState.transitioning:
          case TransportState.noMediaPresent:
            // 保持当前展示，不做断言
            break;
        }
        onCastProgress?.call(castPosition.value, castPlaying.value);
      } catch (_) {
        // 轮询失败静默忽略（设备可能短暂不可达）
      }
    });
  }

  void _stopPositionPoll() {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
  }
}
