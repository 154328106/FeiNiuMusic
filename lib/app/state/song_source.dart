/// 一首歌来自哪个数据源。
///
/// 本 App 原本只有飞牛 NAS 一个源，`SongEntity.id` 直接存飞牛的 GUID。加入
/// 网易云后需要区分来源，但**刻意不加数据库列**：`songs` 表、歌单关联表、
/// 收藏、播放历史、缓存文件名、媒体通知全都以 `SongEntity.id` 为主键，
/// 加列意味着一路改 schema + 迁移 + 所有 DAO。
///
/// 改用 **id 前缀编码**：网易云歌曲的 id 存成 `ne:<网易云歌曲id>`，飞牛的
/// 保持原样（裸 GUID）。这样零迁移，且老数据天然被识别为飞牛。前缀里的
/// 冒号不会与飞牛 GUID 冲突（GUID 是 hex + 连字符）。
enum SongSource {
  feiniu,
  netease,
  subsonic;

  /// 网易云 id 前缀。选 `ne:` 而不是 `netease:` 是为了让缓存文件名短一些。
  static const String neteasePrefix = 'ne:';

  /// Subsonic 协议服务端（Navidrome / NAS 上 4000 端口那个）的 id 前缀。
  static const String subsonicPrefix = 'ss:';

  /// 从 `SongEntity.id` 反推来源。无法识别的一律当飞牛，保证老数据行为不变。
  static SongSource fromSongId(String songId) {
    if (songId.startsWith(neteasePrefix)) return SongSource.netease;
    if (songId.startsWith(subsonicPrefix)) return SongSource.subsonic;
    return SongSource.feiniu;
  }

  /// 把网易云的数字 id 编码成 `SongEntity.id`。
  static String encodeNetease(int neteaseId) => '$neteasePrefix$neteaseId';

  /// 从 `SongEntity.id` 取回网易云数字 id；不是网易云歌曲则返回 null。
  static int? decodeNetease(String songId) {
    if (!songId.startsWith(neteasePrefix)) return null;
    return int.tryParse(songId.substring(neteasePrefix.length));
  }

  /// Subsonic 的曲目 id 本身就是字符串，编解码只是加/去前缀。
  static String encodeSubsonic(String subsonicId) =>
      '$subsonicPrefix$subsonicId';

  static String? decodeSubsonic(String songId) {
    if (!songId.startsWith(subsonicPrefix)) return null;
    return songId.substring(subsonicPrefix.length);
  }
}
