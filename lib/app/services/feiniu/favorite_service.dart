import 'api_client.dart';

/// 飞牛收藏服务
class FeiNiuFavoriteService {
  FeiNiuFavoriteService._();

  static final FeiNiuFavoriteService instance = FeiNiuFavoriteService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 一次翻页抓多少条（取全量时用）。
  static const int _allPageSize = 200;

  /// 取全量收藏：按 [_allPageSize] 逐页翻到底。
  ///
  /// ⚠️ **不再依赖 `size: -1`**（2026-09-18 修）：服务端对 `size=-1` 不返回数据，
  /// 导致收藏状态恒为空（小红心永远不亮）。所有工作正常的页面传的都是正数 size。
  Future<List<dynamic>> _fetchAllFavorites() async {
    final all = <dynamic>[];
    for (var p = 1; ; p++) {
      final pageData = await _api.getFavoriteList(page: p, size: _allPageSize);
      all.addAll(pageData.list);
      if (pageData.list.length < _allPageSize) break;
      if (pageData.total > 0 && all.length >= pageData.total) break;
      if (p >= 50) break; // 兜底，防服务端 total 异常导致死循环
    }
    return all;
  }

  /// 获取收藏歌曲 ID 集合
  Future<Set<String>> getFavoriteIds() async {
    final list = await _fetchAllFavorites();
    return list.map((t) => t.guid as String).toSet();
  }

  /// 获取收藏歌曲列表
  Future<List<dynamic>> getFavoriteList() async {
    return _fetchAllFavorites();
  }

  /// 收藏歌曲
  Future<void> favorite(String trackGuid) async {
    await _api.favoriteTrack(trackGuid);
  }

  /// 批量收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> favoriteAll(List<String> trackGuids) async {
    var failed = 0;
    for (final id in trackGuids) {
      try {
        await _api.favoriteTrack(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 取消收藏
  Future<void> unfavorite(String trackGuid) async {
    await _api.unfavoriteTrack(trackGuid);
  }

  /// 批量取消收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> unfavoriteAll(List<String> trackGuids) async {
    var failed = 0;
    for (final id in trackGuids) {
      try {
        await _api.unfavoriteTrack(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 检查是否已收藏
  Future<bool> isFavorite(String trackGuid) async {
    final ids = await getFavoriteIds();
    return ids.contains(trackGuid);
  }
}
