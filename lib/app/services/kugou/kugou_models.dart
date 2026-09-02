/// 酷狗音乐的数据模型。
///
/// 酷狗的主键是歌曲文件的 `hash`（大写十六进制），不是数字 id —— 取播放
/// 地址、拼签名都靠它。同一首歌不同音质是不同的 hash。
library;

class KugouSong {
  const KugouSong({
    required this.hash,
    required this.name,
    required this.artists,
    required this.album,
    required this.albumId,
    required this.albumAudioId,
    required this.coverUrl,
    required this.durationMs,
    required this.isVip,
  });

  final String hash;
  final String name;

  /// 多位歌手用 ` / ` 连接后的显示名。
  final String artists;
  final String album;

  /// 取播放地址时要一并带上，缺了有些歌会被判成没权限。
  final String? albumId;
  final String? albumAudioId;

  final String? coverUrl;
  final int durationMs;
  final bool isVip;

  /// 酷狗返回的歌名常是「歌手 - 歌名」，拆开只留歌名。
  static (String name, String artist) _splitTitle(String raw, String singer) {
    final idx = raw.indexOf(' - ');
    if (idx <= 0) return (raw.trim(), singer.trim());
    final left = raw.substring(0, idx).trim();
    final right = raw.substring(idx + 3).trim();
    // 前半段等于歌手时才拆，否则「A - B」可能本来就是歌名的一部分。
    if (singer.isEmpty || left == singer) return (right, singer.trim());
    return (raw.trim(), singer.trim());
  }

  static KugouSong? fromJson(Map<String, dynamic> json) {
    final hash = (json['hash'] ?? json['FileHash'] ?? json['audio_id'])
        ?.toString();
    if (hash == null || hash.isEmpty) return null;

    final singer =
        (json['singername'] ?? json['SingerName'] ?? json['author_name'])
            ?.toString() ??
        '';
    final rawTitle =
        (json['songname'] ??
                json['SongName'] ??
                json['filename'] ??
                json['fileName'] ??
                json['audio_name'])
            ?.toString() ??
        '';
    final (name, artists) = _splitTitle(rawTitle, singer);

    // 时长：移动端接口给秒，网页端有的给毫秒。
    final rawDuration =
        (json['duration'] ?? json['Duration'] ?? json['timelen']) as num?;
    final duration = rawDuration?.toInt() ?? 0;
    // timelen 是毫秒，duration 是秒 —— 超过一小时的多半是毫秒。
    final durationMs = duration > 36000 ? duration : duration * 1000;

    // 封面字段各接口不一样：榜单给 album_sizable_cover，移动搜索那个精简
    // 接口不给顶层封面，但通常把模板塞在 trans_param.union_cover 里
    // （形如 http://imge.kugou.com/stdmusic/{size}/….jpg）。
    final trans = json['trans_param'];
    var cover =
        (json['album_sizable_cover'] ??
                json['img'] ??
                json['imgurl'] ??
                json['Image'] ??
                json['AlbumImg'] ??
                (trans is Map ? trans['union_cover'] : null))
            ?.toString();
    if (cover != null && cover.isNotEmpty) {
      cover = cover.replaceAll('{size}', '400');
    } else {
      cover = null;
    }

    // privilege：0/8 可完整播放，10 只有试听，其它多半要会员。
    final privilege = (json['privilege'] as num?)?.toInt();
    final payType = (json['pay_type'] as num?)?.toInt() ?? 0;

    return KugouSong(
      hash: hash.toUpperCase(),
      name: name.isEmpty ? rawTitle : name,
      artists: artists,
      album: (json['album_name'] ?? json['albumname'])?.toString() ?? '',
      albumId: (json['album_id'] ?? json['albumid'])?.toString(),
      albumAudioId: (json['album_audio_id'] ?? json['mixsongid'])?.toString(),
      coverUrl: cover,
      durationMs: durationMs,
      isVip: privilege != null
          ? (privilege != 0 && privilege != 8)
          : payType > 0,
    );
  }
}

/// 酷狗榜单 / 歌单。
class KugouPlaylist {
  const KugouPlaylist({
    required this.id,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
  });

  final int id;
  final String name;
  final String? coverUrl;
  final int trackCount;
}
