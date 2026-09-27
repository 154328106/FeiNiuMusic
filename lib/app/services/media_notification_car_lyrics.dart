/// 车载蓝牙歌词：开启、为当前歌曲且播放中时，返回要写入 `MediaItem.title` 的
/// 歌词行。返回 `null` 表示不覆盖（车机显示真实歌名）。
///
/// AVRCP 只把 TITLE / ARTIST / ALBUM / TRACK_NUMBER / NUM_TRACKS / GENRE /
/// DURATION 等标准属性发给车机，`METADATA_KEY_LYRICS` 不会到达车机（AOSP
/// `avrcp/helpers/Util.java` 的 `bundleToMetadata` 只读这 7 个 key）。因此用
/// `title` 携带当前歌词行，让车机在 TITLE 位置显示歌词。
///
/// 暂停时不覆盖：暂停态保留真实 queueIndex（见
/// `MediaNotificationService._stateFromSnap`），AOSP AVRCP 的
/// `isMetadataSynced()` 要求队列当前项 title 与会话 metadata title 一致才
/// 放行更新，歌词行必然不一致；暂停回退真实歌名即可让暂停态完全正常
/// （列表 + 高亮 + 歌名），播放中再由 queueIndex=null 绕过该检查。
String? carLyricsTitleOverride({
  required bool carLyricsEnabled,
  required bool isCurrentSong,
  required bool isPlaying,
  required String? currentCarLyricLine,
}) {
  if (!carLyricsEnabled || !isCurrentSong || !isPlaying) return null;
  final line = currentCarLyricLine?.trim() ?? '';
  return line.isEmpty ? null : line;
}
