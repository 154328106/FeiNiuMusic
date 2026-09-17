import 'package:flutter/foundation.dart';

import '../state/song_source.dart';
import '../state/song_state.dart';
import 'feiniu/favorite_service.dart';
import 'feiniu/playlist_service.dart';
import 'kugou/kugou_api_client.dart';
import 'kugou/kugou_auth.dart';
import 'netease/netease_api_client.dart';
import 'qq/qq_api_client.dart';
import 'qq/qq_auth.dart';
import 'source/music_source.dart';

/// 某个来源在「收藏 / 添加到歌单」上的能力。
class SongActionCapability {
  const SongActionCapability({
    required this.label,
    required this.loggedIn,
    required this.canReadPlaylists,
    required this.canAddToPlaylist,
    required this.canFavorite,
  });

  /// 源的中文名，用于提示文案。
  final String label;

  /// 该源是否已登录。没登录时即便支持也做不了。
  final bool loggedIn;

  final bool canReadPlaylists;
  final bool canAddToPlaylist;
  final bool canFavorite;
}

/// 「小红心」「添加到歌单」的**来源路由**。
///
/// 背景（2026-09-18）：[SongEntity.id] 是带来源前缀的（飞牛 = 裸 GUID、
/// 网易 = `ne:`、QQ = `qq:`、酷狗 = `kg:`，见 [SongSource]），但收藏/歌单的 UI
/// 以前**一律**把这个 id 当飞牛 `trackGUID` 发给 NAS —— 于是在线音源的歌点红心
/// 恒「操作失败」，加歌单则静默无反应。而且飞牛 NAS 本来也存不了不在自己曲库里
/// 的歌，这不是「改个 id 就能成」的事。
///
/// 正确做法：**按歌曲来源分发** —— 酷狗的歌进酷狗账号的歌单/收藏，网易的进网易。
/// 本类只负责路由和能力查询，具体请求仍交给各家自己的 client。
///
/// 当前各源能力（能力不齐的那几个，UI 用 [capabilityOf] 给明确提示，
/// 而不是等接口抛错再报「操作失败」）：
///
/// | 源   | 读我的歌单 | 加歌进歌单 | 收藏 |
/// |------|-----------|-----------|------|
/// | 飞牛 | ✅        | ✅        | ✅          |
/// | 酷狗 | ✅        | ✅        | ✅（仅添加） |
/// | 网易 | ✅        | ❌ 待做   | ✅          |
/// | QQ   | ✅        | ❌ 待做   | ❌ 待做      |
///
/// 酷狗的收藏就是「往『我喜欢』歌单加歌」（它没有独立的收藏接口），所以只做了
/// 添加；取消收藏要另一个 del_song 接口，暂未实现，点了会如实提示。
///
/// 「待做」= 那几家的私有写接口还没实现（需要各自的签名方案），不是这里少写了
/// 分支。补齐时只改本文件对应分支即可，UI 不用动。
class SongActionsService {
  SongActionsService._();

  static final SongActionsService instance = SongActionsService._();

  final FeiNiuFavoriteService _fnFavorite = FeiNiuFavoriteService.instance;
  final FeiNiuPlaylistService _fnPlaylist = FeiNiuPlaylistService.instance;

  /// 把本服务抛出的异常转成能直接给用户看的一句话。
  ///
  /// 之前 UI 一律 catch 成「操作失败」，用户完全不知道是没登录、还是这个源
  /// 压根不支持 —— 这里把原因透出去。
  static String describeError(Object e) {
    if (e is UnsupportedError) return e.message ?? '暂不支持该操作';
    if (e is StateError) return e.message;
    return '操作失败';
  }

  /// 查询某来源当前能做什么。
  SongActionCapability capabilityOf(SongSource source) {
    switch (source) {
      case SongSource.feiniu:
        return const SongActionCapability(
          label: '飞牛',
          // 飞牛账号是 App 的入口，能进到播放页就一定登录了。
          loggedIn: true,
          canReadPlaylists: true,
          canAddToPlaylist: true,
          canFavorite: true,
        );
      case SongSource.kugou:
        return SongActionCapability(
          label: '酷狗音乐',
          loggedIn: KugouAuth.instance.isLoggedIn.value,
          canReadPlaylists: true,
          canAddToPlaylist: true,
          canFavorite: true,
        );
      case SongSource.netease:
        return SongActionCapability(
          label: '网易云音乐',
          loggedIn: NetEaseApiClient.instance.isLoggedIn,
          canReadPlaylists: true,
          canAddToPlaylist: false,
          canFavorite: true,
        );
      case SongSource.qq:
        return SongActionCapability(
          label: 'QQ音乐',
          loggedIn: QQAuth.instance.isLoggedIn.value,
          canReadPlaylists: true,
          canAddToPlaylist: false,
          canFavorite: false,
        );
    }
  }

  /// 「我的歌单」——**可写入**的那种，供「添加到歌单」选择器用。
  ///
  /// 注意与首页 `MusicSource.playlists()` 区分：那个是浏览用的，会混入榜单、
  /// 歌单广场等**别人的**歌单，往里写没有意义。
  ///
  /// 返回的 [SourcePlaylist.id] 是**该平台的原始 id**（不加来源前缀）——
  /// 调用方本来就带着 [SongSource] 一起传回 [addToPlaylist]，不需要再编码一次。
  /// 未登录或取不到时返回空列表，调用方显示「暂无歌单」即可。
  Future<List<SourcePlaylist>> myPlaylists(SongSource source) async {
    try {
      switch (source) {
        case SongSource.feiniu:
          final lists = await _fnPlaylist.getPlaylistList();
          return lists
              .map(
                (p) => SourcePlaylist(
                  id: p.guid,
                  name: p.name,
                  coverId: p.coverId,
                  trackCount: p.trackCount,
                ),
              )
              .toList();

        case SongSource.kugou:
          if (!KugouAuth.instance.isLoggedIn.value) return const [];
          final lists = await KugouApiClient.instance.userPlaylists();
          return lists
              .map(
                (p) => SourcePlaylist(
                  id: '${p.id}',
                  name: p.name,
                  coverId: p.coverUrl,
                  trackCount: p.trackCount,
                ),
              )
              .toList();

        case SongSource.netease:
          final api = NetEaseApiClient.instance;
          if (!api.isLoggedIn) return const [];
          final user = await api.account();
          final lists = await api.userPlaylists(user.userId);
          return lists
              .map(
                (p) => SourcePlaylist(
                  id: '${p.id}',
                  name: p.name,
                  coverId: p.coverUrl,
                  trackCount: p.trackCount,
                ),
              )
              .toList();

        case SongSource.qq:
          if (!QQAuth.instance.isLoggedIn.value) return const [];
          final lists = await QQApiClient.instance.userPlaylists();
          return lists
              .map(
                (p) => SourcePlaylist(
                  id: '${p.dirId ?? p.id}',
                  name: p.name,
                  coverId: p.coverUrl,
                  trackCount: p.trackCount,
                ),
              )
              .toList();
      }
    } catch (e) {
      debugPrint('[SongActions] myPlaylists($source) error: $e');
      return const [];
    }
  }

  /// 查询是否已收藏。
  ///
  /// 网易目前没有便宜的「单曲是否已收藏」接口，恒返回 false（红心不回显，
  /// 但点击仍然生效）。补上之后改这里即可。
  Future<bool> isFavorite(SongEntity song) async {
    try {
      switch (song.source) {
        case SongSource.feiniu:
          return await _fnFavorite.isFavorite(song.id);
        case SongSource.netease:
        case SongSource.kugou:
        case SongSource.qq:
          return false;
      }
    } catch (e) {
      debugPrint('[SongActions] isFavorite error: $e');
      return false;
    }
  }

  /// 设置 / 取消收藏。不支持的源抛 [UnsupportedError]，调用方据此给提示。
  Future<void> setFavorite(SongEntity song, bool value) async {
    final cap = capabilityOf(song.source);
    if (!cap.canFavorite) {
      throw UnsupportedError('${cap.label}暂不支持收藏');
    }
    if (!cap.loggedIn) {
      throw StateError('请先登录${cap.label}');
    }
    switch (song.source) {
      case SongSource.feiniu:
        if (value) {
          await _fnFavorite.favorite(song.id);
        } else {
          await _fnFavorite.unfavorite(song.id);
        }
        return;
      case SongSource.netease:
        final id = song.neteaseId;
        if (id == null) throw StateError('这首歌没有网易云 id');
        final ok = await NetEaseApiClient.instance.like(id, liked: value);
        if (!ok) throw StateError('网易云收藏接口返回失败');
        return;
      case SongSource.kugou:
        // 酷狗没有独立的收藏接口：收藏 = 往「我喜欢」这个歌单里加歌。
        // 取消收藏要用 del_song（另一个接口），先不做，如实报出来。
        if (!value) {
          throw UnsupportedError('酷狗暂不支持取消收藏，请到酷狗 App 里操作');
        }
        final listId = await KugouApiClient.instance.favoritePlaylistId();
        if (listId == null) {
          throw StateError('没找到酷狗「我喜欢」歌单');
        }
        await KugouApiClient.instance.addSongsToPlaylist(listId, [
          _kugouRef(song),
        ]);
        return;
      case SongSource.qq:
        throw UnsupportedError('${cap.label}暂不支持收藏');
    }
  }

  /// 把一首酷狗歌曲转成加歌载荷。
  ///
  /// 四个字段全部来自 [SongEntity]，不用再打一次网络 —— `album_id` 藏在 `codec`、
  /// `mixsongid` 藏在 `audioSpec`（见 `KugouPlaybackService.toSongEntity`）。
  static KugouAddSongRef _kugouRef(SongEntity song) {
    final hash = SongSource.decodeKugou(song.id) ?? '';
    if (hash.isEmpty) throw StateError('这首歌没有酷狗 hash');
    return KugouAddSongRef(
      name: song.title,
      hash: hash,
      albumId: int.tryParse(song.codec ?? '') ?? 0,
      mixSongId: int.tryParse(song.audioSpec ?? '') ?? 0,
    );
  }

  /// 把歌曲加进该来源的某个歌单。
  ///
  /// [songIds] 是带来源前缀的 [SongEntity.id]；[songs] 是对应的完整实体。
  /// **酷狗必须有 [songs]** —— 它的加歌接口除了 hash 还要 name / album_id /
  /// mixsongid，光靠 id 凑不出来。拿不到实体的调用方（如歌单页多选）传 null 即可，
  /// 飞牛那条路只用 id，不受影响。
  Future<void> addToPlaylist(
    SongSource source,
    String playlistId,
    List<String> songIds, {
    List<SongEntity>? songs,
  }) async {
    final cap = capabilityOf(source);
    if (!cap.canAddToPlaylist) {
      throw UnsupportedError('${cap.label}暂不支持添加到歌单');
    }
    if (!cap.loggedIn) {
      throw StateError('请先登录${cap.label}');
    }
    switch (source) {
      case SongSource.feiniu:
        // 飞牛的 id 就是裸 trackGUID，原样传。
        await _fnPlaylist.addTracks(playlistId, songIds);
        return;
      case SongSource.kugou:
        final list = songs ?? const <SongEntity>[];
        if (list.isEmpty) {
          throw StateError('缺少歌曲信息，请从播放页或歌曲列表里操作');
        }
        final listId = int.tryParse(playlistId) ?? 0;
        if (listId <= 0) throw StateError('酷狗歌单 id 异常');
        await KugouApiClient.instance.addSongsToPlaylist(
          listId,
          list.map(_kugouRef).toList(),
        );
        return;
      case SongSource.netease:
      case SongSource.qq:
        throw UnsupportedError('${cap.label}暂不支持添加到歌单');
    }
  }
}
