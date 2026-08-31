import 'dart:convert';

import '../../state/song_source.dart';
import '../../state/song_state.dart';
import 'subsonic_api_client.dart';
import 'subsonic_response.dart';

/// 把 Subsonic 的曲目 JSON 转成 App 内部的 [SongEntity]。
///
/// 与网易云那套的关键差别：Subsonic 的 `/rest/stream.view?id=…` 是**稳定直链**
/// （鉴权走 query 参数），不是带签名的临时地址，所以可以直接写进
/// [SongEntity.uri] 持久化复用，播放前不需要重新解析。
///
/// 注意 `coverArt` 是**独立于曲目 id 的另一个 id**，不能拿 songId 去取封面。
/// 这里把封面完整 URL 存进 `coverId`，与网易云的做法一致 —— ArtworkWidget
/// 认出 http 开头就当完整地址用，不去拼飞牛的 `/static/cover`。
class SubsonicTrackMapper {
  const SubsonicTrackMapper._();

  static SongEntity toSongEntity(Map<String, Object?> json) {
    final rawId = subsonicStr(json['id']);
    final api = SubsonicApiClient.instance;

    final artistName = subsonicStr(json['artist'], fallback: '未知歌手');
    final albumName = subsonicStr(json['album'], fallback: '未知专辑');

    // 时长 Subsonic 给的是**秒**，App 内部一律用毫秒。
    final durationSec = subsonicInt(json['duration']);

    final coverArt = subsonicStr(json['coverArt']);

    return SongEntity(
      id: SongSource.encodeSubsonic(rawId),
      title: subsonicStr(json['title'], fallback: '未知标题'),
      // artist / album 按仓库既有约定写成 JSON，这样 artistDisplayName 等
      // 访问器和直接 jsonDecode 的消费方都走正常路径。Subsonic 没有飞牛的
      // guid 概念，用它自己的 artistId / albumId 填。
      artist: jsonEncode([
        {'guid': subsonicStr(json['artistId']), 'name': artistName},
      ]),
      album: jsonEncode({
        'guid': subsonicStr(json['albumId']),
        'name': albumName,
      }),
      uri: rawId.isEmpty ? null : api.streamUrl(rawId),
      durationMs: durationSec > 0 ? durationSec * 1000 : null,
      bitrate: subsonicInt(json['bitRate']) > 0
          ? subsonicInt(json['bitRate'])
          : null,
      fileSize: subsonicInt(json['size']) > 0
          ? subsonicInt(json['size'])
          : null,
      format: _formatOf(json),
      isFavorite: json['starred'] != null,
      coverId: coverArt.isEmpty ? null : api.coverUrl(coverArt),
      trackNumber: subsonicInt(json['track']) > 0
          ? subsonicInt(json['track'])
          : null,
      discNumber: subsonicInt(json['discNumber']) > 0
          ? subsonicInt(json['discNumber'])
          : null,
    );
  }

  /// 优先用 `suffix`（文件扩展名），没有再从 `contentType` 里取后半段。
  /// 格式决定解码引擎路由，取不到就留空交给运行时探测。
  static String? _formatOf(Map<String, Object?> json) {
    final suffix = subsonicStr(json['suffix']).toLowerCase();
    if (suffix.isNotEmpty) return suffix;
    final contentType = subsonicStr(json['contentType']);
    final slash = contentType.lastIndexOf('/');
    if (slash >= 0 && slash < contentType.length - 1) {
      return contentType.substring(slash + 1).toLowerCase();
    }
    return null;
  }

  static List<SongEntity> toSongEntities(List<Map<String, Object?>> list) =>
      list.map(toSongEntity).toList(growable: false);
}
