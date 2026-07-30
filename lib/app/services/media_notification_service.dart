import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/lyrics/lyrics_service.dart';
import '../services/feiniu/api_client.dart';
import '../services/feiniu/favorite_service.dart';
import '../state/song_state.dart';
import '../state/settings_state.dart';
import 'android_platform_service.dart';
import 'player_service.dart';

class MediaNotificationService {
  static AudioHandler? _audioHandler;
  static VoidCallback? _initListener;
  static bool _initStarted = false;

  static Future<void> init({bool force = false}) async {
    if (_audioHandler != null || _initStarted) return;
    await MediaNotificationSettings.ensureLoaded();
    final player = PlayerService.instance;
    final snap = player.snapshot.value;
    if (!force && snap.song == null && !snap.isPlaying) {
      if (_initListener == null) {
        _initListener = () {
          final current = player.snapshot.value;
          if (current.song == null && !current.isPlaying) return;
          if (_initListener != null) {
            player.snapshot.removeListener(_initListener!);
            _initListener = null;
          }
          init(force: true);
        };
        player.snapshot.addListener(_initListener!);
      }
      return;
    }
    _initStarted = true;
    _debugLog('init start force=$force');
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        _debugLog('requesting Android notification permission');
        await Permission.notification.request();
      }
    }
    _audioHandler = await AudioService.init(
      builder: () => _NagoAudioHandler(PlayerService.instance),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.feiniu.music.playback',
        androidNotificationChannelName: '音乐播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidShowNotificationBadge: false,
      ),
    );
    _debugLog('init completed');
    _initStarted = false;
  }

  static void _debugLog(String message) {
    if (!kDebugMode) return;
    debugPrint('[MediaNotification] $message');
  }
}

class _NagoAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final PlayerService player;
  static const String _actionCloseApp = 'close_app';
  static const String _actionFavorite = 'favorite';
  String? _currentLyricLine;
  String? _lastSongId;
  bool _isFavorite = false;
  String? _lastQueueKey;
  String? _lastMediaItemKey;
  String? _lastPlaybackStateKey;
  bool _supportsCustomActions = true;

  // 封面本地缓存
  String? _coverDirPath;
  String? _lastCoverId;
  Uri? _cachedCoverUri;

  _NagoAudioHandler(this.player) {
    player.snapshot.addListener(_syncFromPlayer);
    LyricsService.instance.currentLineText.addListener(_onLyricLineChanged);
    MediaNotificationSettings.showLyrics.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.lyricOnTop.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.showCloseAction.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.showFavoriteAction.addListener(
      _onNotificationSettingsChanged,
    );
    _currentLyricLine = LyricsService.instance.currentLineText.value;
    _loadPlatformCapabilities();
    _syncFromPlayer();
  }

  Future<void> _loadPlatformCapabilities() async {
    _supportsCustomActions = await AndroidPlatformService.instance
        .supportsNotificationCustomActions();
    _debugLog('supports custom actions=$_supportsCustomActions');
    _lastPlaybackStateKey = null;
    _syncPlaybackState(player.snapshot.value);
  }

  void _debugLog(String message) {
    if (!kDebugMode) return;
    debugPrint('[MediaNotification] $message');
  }

  // ---- 封面图本地下载 ----

  Future<String> _coverDir() async {
    if (_coverDirPath == null) {
      final dir = await getTemporaryDirectory();
      _coverDirPath = '${dir.path}/notification_covers';
      await Directory(_coverDirPath!).create(recursive: true);
    }
    return _coverDirPath!;
  }

  /// 使用认证头下载封面图到本地临时文件，
  /// 因为 Android 系统通知栏加载 artUri 时不携带 Cookie 认证头。
  Future<Uri?> _downloadCoverToLocal(String coverId, {int? updatedAt}) async {
    final api = FeiNiuApiClient.instance;
    if (api.token.isEmpty) return null;

    final dir = await _coverDir();
    final suffix = updatedAt != null && updatedAt > 0 ? '_$updatedAt' : '';
    final filePath = '$dir/${coverId}_512$suffix.jpg';
    final file = File(filePath);

    if (await file.exists()) {
      return Uri.file(filePath);
    }

    try {
      final httpClient = HttpClient();
      try {
        final request = await httpClient.getUrl(
          Uri.parse(api.coverUrl(coverId, size: 512, updatedAt: updatedAt)),
        );
        if (api.token.isNotEmpty) {
          final headers = api.authHeaders();
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          await file.writeAsBytes(bytes);
          return Uri.file(filePath);
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (e) {
      _debugLog('cover download failed: $e');
    }
    return null;
  }

  // ---- MediaItem / PlaybackState 构建 ----

  MediaItem _itemFromSong(SongEntity song) {
    final lyricLine = MediaNotificationSettings.showLyrics.value
        ? _currentLyricLine
        : null;
    final titleText = song.title.trim();
    final artistText = song.artistDisplayName.trim();
    final songAndArtist = artistText.isEmpty
        ? titleText
        : '$titleText · $artistText';
    final albumName = song.albumDisplayName;

    // artUri: Android 优先使用本地下载的封面图
    Uri? artUri;
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      if (_cachedCoverUri != null) {
        artUri = _cachedCoverUri;
      } else {
        // Android 和 iOS 都使用 API URL，系统可能不携带 Cookie 但最差情况是显示空白
        artUri = Uri.tryParse(
          FeiNiuApiClient.instance.coverUrl(song.coverId!, size: 512, updatedAt: song.updatedAt),
        );
      }
    }

    final lyricOnTop = MediaNotificationSettings.lyricOnTop.value;
    if (lyricOnTop && lyricLine != null) {
      return MediaItem(
        id: song.id,
        title: lyricLine,
        artist: songAndArtist,
        album: albumName,
        duration: song.durationMs != null
            ? Duration(milliseconds: song.durationMs!)
            : null,
        displayTitle: lyricLine,
        displaySubtitle: songAndArtist,
        displayDescription: artistText.isEmpty ? null : artistText,
      );
    }
    final effectiveArtist = lyricLine ?? song.artistDisplayName;
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: effectiveArtist,
      album: albumName,
      artUri: artUri,
      duration: song.durationMs != null
          ? Duration(milliseconds: song.durationMs!)
          : null,
      displayTitle: song.title,
      displaySubtitle: lyricLine,
      displayDescription: lyricLine != null ? song.artistDisplayName : null,
    );
  }

  PlaybackState _stateFromSnap(PlaybackSnapshot snap) {
    final playing = snap.isPlaying;
    final showClose =
        _supportsCustomActions &&
        MediaNotificationSettings.showCloseAction.value;
    final showFavorite =
        _supportsCustomActions &&
        MediaNotificationSettings.showFavoriteAction.value;
    final favoriteIcon = _isFavorite
        ? 'drawable/audio_service_favorite_on'
        : 'drawable/audio_service_favorite';
    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ];
    if (showClose) {
      controls.add(
        MediaControl.custom(
          name: _actionCloseApp,
          androidIcon: 'drawable/audio_service_close',
          label: '关闭',
        ),
      );
    }
    if (showFavorite) {
      controls.add(
        MediaControl.custom(
          name: _actionFavorite,
          androidIcon: favoriteIcon,
          label: _isFavorite ? '已收藏' : '收藏',
        ),
      );
    }
    final processing = snap.queue.isEmpty
        ? AudioProcessingState.idle
        : AudioProcessingState.ready;
    return PlaybackState(
      controls: controls,
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processing,
      playing: playing,
      updatePosition: snap.position,
      bufferedPosition: snap.bufferedPosition,
      speed: 1.0,
      queueIndex: snap.index >= 0 ? snap.index : null,
    );
  }

  // ---- 同步方法 ----

  void _syncFromPlayer() {
    final snap = player.snapshot.value;
    final songId = snap.song?.id;
    final songChanged = songId != _lastSongId;
    if (songId != _lastSongId) {
      _lastSongId = songId;
      _currentLyricLine = null;
      _debugLog('song changed to ${snap.song?.title ?? 'none'}');
    }

    // 歌曲切换时异步下载封面图到本地
    if (songChanged) {
      final song = snap.song;
      _cachedCoverUri = null;
      if (song != null &&
          song.coverId != null &&
          song.coverId!.isNotEmpty &&
          song.coverId != _lastCoverId) {
        _lastCoverId = song.coverId;
        if (Platform.isAndroid) {
          _downloadCoverToLocal(song.coverId!, updatedAt: song.updatedAt).then((localUri) {
            if (localUri != null && song.id == _lastSongId) {
              _cachedCoverUri = localUri;
              _syncMediaItem();
            }
          });
        }
      }
    }

    _syncQueue(snap);
    _syncMediaItem();
    _syncPlaybackState(snap);
    if (songChanged) {
      _refreshFavoriteState();
    }
  }

  void _syncQueue(PlaybackSnapshot snap) {
    final queueKey = snap.queue.map((song) => song.id).join('|');
    if (queueKey == _lastQueueKey) return;
    _lastQueueKey = queueKey;
    queue.add(snap.queue.map(_itemFromSong).toList());
  }

  void _syncMediaItem() {
    final current = player.snapshot.value.song;
    final item = current != null ? _itemFromSong(current) : null;
    final itemKey = item == null
        ? 'none'
        : [
            item.id,
            item.title,
            item.artist ?? '',
            item.displayTitle ?? '',
            item.displaySubtitle ?? '',
            item.artUri?.toString() ?? '',
          ].join('|');
    if (itemKey == _lastMediaItemKey) return;
    _lastMediaItemKey = itemKey;
    mediaItem.add(item);
  }

  void _syncPlaybackState(PlaybackSnapshot snap) {
    final next = _stateFromSnap(snap);
    final stateKey = [
      snap.song?.id ?? '',
      snap.index,
      snap.isPlaying,
      next.processingState.name,
      snap.position.inMilliseconds,
      snap.bufferedPosition.inMilliseconds,
      snap.duration?.inMilliseconds ?? -1,
      _isFavorite,
      MediaNotificationSettings.showLyrics.value,
      MediaNotificationSettings.lyricOnTop.value,
      MediaNotificationSettings.showCloseAction.value,
      MediaNotificationSettings.showFavoriteAction.value,
      _supportsCustomActions,
    ].join('|');
    if (stateKey == _lastPlaybackStateKey) return;
    _lastPlaybackStateKey = stateKey;
    playbackState.add(next);
  }

  void _onLyricLineChanged() {
    _currentLyricLine = LyricsService.instance.currentLineText.value;
    _syncMediaItem();
  }

  void _onNotificationSettingsChanged() {
    if (!MediaNotificationSettings.showLyrics.value) {
      _currentLyricLine = null;
    } else {
      _currentLyricLine = LyricsService.instance.currentLineText.value;
    }
    _syncMediaItem();
    playbackState.add(_stateFromSnap(player.snapshot.value));
  }

  void _refreshFavoriteState() {
    final song = player.snapshot.value.song;
    if (song == null) return;
    // 从服务器查询收藏状态
    FeiNiuFavoriteService.instance.isFavorite(song.id).then((fav) {
      _updateFavorite(fav);
    });
  }

  void _updateFavorite(bool value) {
    if (_isFavorite == value) return;
    _isFavorite = value;
    _debugLog('favorite state changed: $_isFavorite');
    playbackState.add(_stateFromSnap(player.snapshot.value));
  }

  // ---- 通知按钮回调 ----

  @override
  Future<void> skipToNext() {
    _debugLog('skipToNext action');
    return player.next();
  }

  @override
  Future<void> skipToPrevious() {
    _debugLog('skipToPrevious action');
    return player.previous();
  }

  @override
  Future<void> seek(Duration position) {
    _debugLog('seek action ${position.inMilliseconds}ms');
    return player.seek(position);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _debugLog('skipToQueueItem action index=$index');
    return player.next(); // 简化实现
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    _debugLog('customAction name=$name');
    if (name == _actionCloseApp) {
      _debugLog('close action');
      await stop();
      return;
    }
    if (name == _actionFavorite) {
      final song = player.snapshot.value.song;
      if (song == null) return;
      if (_isFavorite) {
        _debugLog('favorite remove action song=${song.title}');
        try {
          await FeiNiuFavoriteService.instance.unfavorite(song.id);
          _updateFavorite(false);
        } catch (e) {
          _debugLog('unfavorite failed: $e');
        }
      } else {
        _debugLog('favorite add action song=${song.title}');
        try {
          await FeiNiuFavoriteService.instance.favorite(song.id);
          _updateFavorite(true);
        } catch (e) {
          _debugLog('favorite failed: $e');
        }
      }
      return;
    }
    return super.customAction(name, extras);
  }

  @override
  Future<void> play() {
    _debugLog('play action');
    return player.play();
  }

  @override
  Future<void> pause() {
    _debugLog('pause action');
    return player.pause();
  }

  @override
  Future<void> stop() {
    _debugLog('stop action');
    return player.stopAndClear();
  }
}
