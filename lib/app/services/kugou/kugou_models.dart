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

  /// 去掉文件扩展名。云端歌单的标题字段是文件名，带着 .mp3 / .flac。
  static String _stripExtension(String raw) {
    final value = raw.trim();
    for (final ext in const ['.mp3', '.flac', '.ape', '.wav', '.m4a', '.ogg']) {
      if (value.toLowerCase().endsWith(ext)) {
        return value.substring(0, value.length - ext.length).trim();
      }
    }
    return value;
  }

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
    final hash =
        (json['hash'] ??
                json['FileHash'] ??
                json['file_hash'] ??
                json['audio_id'])
            ?.toString();
    if (hash == null || hash.isEmpty) return null;

    // 歌手：顶层字段之外还要认 `authors` 数组。
    //
    // 榜单接口（m.kugou.com/rank/info，漫游和首页推荐都走它）**根本没有
    // singername**，歌手在 `authors: [{author_name}]` 里 —— 只找顶层字段
    // 的话整个榜单都是「未知歌手」。合唱会有多个，用 / 连起来。
    var singer =
        (json['singername'] ??
                json['SingerName'] ??
                json['author_name'] ??
                json['singer'])
            ?.toString() ??
        '';
    if (singer.isEmpty) {
      final authors = json['authors'];
      if (authors is List) {
        final names = [
          for (final a in authors)
            if (a is Map && a['author_name'] != null)
              a['author_name'].toString().trim(),
        ].where((n) => n.isNotEmpty).toList();
        if (names.isNotEmpty) singer = names.join(' / ');
      }
    }
    // 标题字段各接口给的东西不一样，而且**同一个接口里也不一致**：云端歌单
    // 有时给「周杰伦 - 晴天.mp3」，有时只给「晴天.mp3」。所以不能按固定顺序
    // 取第一个非空的（上一版就是这么写的，结果收藏里全是「歌名.mp3」），
    // 要在所有候选里挑信息最全的那个 —— 带「歌手 - 」的优先。
    final titleCandidates = [
      for (final key in const [
        'songname',
        'SongName',
        'name',
        'filename',
        'fileName',
        'audio_name',
      ])
        json[key]?.toString() ?? '',
    ].where((v) => v.trim().isNotEmpty).map(_stripExtension).toList();
    final rawTitle = titleCandidates.isEmpty
        ? ''
        : titleCandidates.firstWhere(
            (v) => v.contains(' - '),
            orElse: () => titleCandidates.first,
          );
    // 还是没歌手，就从「歌手 - 歌名」里取左半边。云端歌单那些只给文件名的
    // 记录全靠这一条 —— 否则它们同样是「未知歌手」。
    if (singer.isEmpty) {
      final dash = rawTitle.indexOf(' - ');
      if (dash > 0) singer = rawTitle.substring(0, dash).trim();
    }
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
                json['sizable_cover'] ??
                json['cover'] ??
                json['pic'] ??
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

/// 扫码登录的状态。
enum KugouScanState { waiting, scanned, expired, success }

class KugouScanResult {
  const KugouScanResult(this.state, {this.nickname});

  final KugouScanState state;
  final String? nickname;
}
