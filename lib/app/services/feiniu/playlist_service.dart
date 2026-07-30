import 'api_client.dart';
import 'api_models.dart';

/// 飞牛歌单服务（所有操作通过 API）
class FeiNiuPlaylistService {
  FeiNiuPlaylistService._();

  static final FeiNiuPlaylistService instance = FeiNiuPlaylistService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取所有歌单
  Future<List<FeiNiuPlaylist>> getPlaylistList() async {
    final pageData = await _api.getPlaylistList();
    return pageData.list;
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

  /// 创建歌单（自动随机封面）
  Future<FeiNiuPlaylist> createPlaylist(String name) async {
    // 先上传随机封面获取 coverId
    final coverId = await _api.uploadCover();
    final playlist = await _api.createPlaylist(name, coverId: coverId);
    return playlist;
  }

  /// 删除歌单
  Future<void> deletePlaylist(String guid) async {
    await _api.deletePlaylist(guid);
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
}
