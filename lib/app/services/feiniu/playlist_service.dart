import 'api_client.dart';
import 'api_models.dart';

/// 飞牛歌单服务（所有操作通过 API）
class FeiNiuPlaylistService {
  FeiNiuPlaylistService._();

  static final FeiNiuPlaylistService instance = FeiNiuPlaylistService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 一次翻页抓多少条（取全量时用）。
  static const int _allPageSize = 200;

  /// 获取歌单列表。
  ///
  /// 不传 `page`/`size` = **取全量**（歌单选择器等场景）：内部按 [_allPageSize]
  /// 逐页翻到底再合并。
  ///
  /// ⚠️ 这里**不再用 `size: -1` 表示「一次返回全部」**（2026-09-18 修）：
  /// 服务端对 `size=-1` 不返回数据，导致「添加到歌单」弹框恒显示「暂无歌单」。
  /// 佐证：首页(`size:10`)、歌单页(显式分页)、收藏页(显式分页)全都传正数且正常，
  /// 全项目只有这里和 `getFavoriteList` 用 `-1`，而这两处正好就是坏掉的两个功能。
  /// 歌单页传入 `page`/`size` 做滚动加载更多，行为不变。
  Future<List<FeiNiuPlaylist>> getPlaylistList({int? page, int? size}) async {
    if (page != null || size != null) {
      final pageData = await _api.getPlaylistList(
        page: page ?? 1,
        size: size ?? _allPageSize,
      );
      return pageData.list;
    }
    final all = <FeiNiuPlaylist>[];
    for (var p = 1; ; p++) {
      final pageData = await _api.getPlaylistList(page: p, size: _allPageSize);
      all.addAll(pageData.list);
      // 取够了 / 这一页没满 / 服务端没返回数据 → 到底了
      if (pageData.list.length < _allPageSize) break;
      if (pageData.total > 0 && all.length >= pageData.total) break;
      if (p >= 50) break; // 兜底，别因为服务端 total 异常转成死循环
    }
    return all;
  }

  /// 获取歌单内歌曲
  Future<List<FeiNiuTrack>> getPlaylistTracks(
    String playlistGuid, {
    int page = 1,
    int size = 300,
  }) async {
    final pageData = await _api.getPlaylistTracks(
      playlistGUID: playlistGuid,
      page: page,
      size: size,
    );
    return pageData.list;
  }

  /// 创建歌单。
  ///
  /// 未传 [coverId] 时上传随机封面；传入用户自选封面的 coverId 时直接使用。
  Future<FeiNiuPlaylist> createPlaylist(String name, {String? coverId}) async {
    // 没有自定义封面时上传随机封面
    final finalCoverId = coverId ?? await _api.uploadCover();
    final playlist = await _api.createPlaylist(name, coverId: finalCoverId);
    return playlist;
  }

  /// 上传本地图片作为歌单封面，返回 coverId。失败时抛异常。
  Future<String> uploadCoverFromFile(String imagePath) async {
    return _api.uploadCoverFromFile(imagePath);
  }

  /// 删除歌单
  Future<void> deletePlaylist(String guid) async {
    await _api.deletePlaylist(guid);
  }

  /// 清除歌单内无效歌曲，返回清除数量
  Future<int> purgeInvalidTracks(String playlistGuid) async {
    return _api.purgeInvalidTracks(playlistGuid);
  }

  /// 编辑歌单（名称/封面）
  Future<void> editPlaylist({
    required String guid,
    String? name,
    String? coverId,
  }) async {
    await _api.editPlaylist(guid: guid, name: name, coverId: coverId);
  }

  /// 添加歌曲到歌单
  Future<void> addTrack(String playlistGuid, String trackGuid) async {
    await _api.addTrackToPlaylist(playlistGuid, [trackGuid]);
  }

  /// 添加多首歌曲到歌单
  Future<void> addTracks(
      String playlistGuid, List<String> trackGuids) async {
    await _api.addTrackToPlaylist(playlistGuid, trackGuids);
  }

  /// 从歌单移除歌曲
  Future<void> removeTrack(String playlistGuid, String trackGuid) async {
    await _api.removeTrackFromPlaylist(playlistGuid, trackGuid);
  }

  /// 从歌单批量移除歌曲（一次请求提交全部）
  Future<void> removeTracks(
    String playlistGuid,
    List<String> trackGuids,
  ) async {
    await _api.removeTracksFromPlaylist(playlistGuid, trackGuids);
  }
}
