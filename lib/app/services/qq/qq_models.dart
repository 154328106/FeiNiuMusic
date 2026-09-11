/// QQ 音乐的数据模型。
///
/// 和网易云一样只覆盖最小闭环（搜索 / 播放 / 歌词 / 歌单）需要的字段。
/// QQ 的同一个实体在不同接口里字段名也不统一（搜索走 `songmid`/`songname`，
/// musicu 走 `mid`/`title`），解析时两套都认。
library;

class QQSong {
  const QQSong({
    required this.mid,
    required this.name,
    required this.artists,
    this.singers = const [],
    required this.album,
    required this.albumMid,
    required this.mediaMid,
    required this.durationMs,
    required this.payPlay,
  });

  /// 歌曲 mid（QQ 的主键是字符串，不是数字）。
  final String mid;

  final String name;

  /// 多位歌手用 ` / ` 连接后的显示名。
  final String artists;

  /// 歌手的名字与 mid，按接口返回的顺序。用来取歌手头像。
  final List<({String name, String mid})> singers;
  final String album;

  /// 专辑 mid，用来拼封面地址。
  final String? albumMid;

  /// 取播放地址时拼文件名要用。独家 VIP 歌的 media_mid 常与 mid 不同。
  final String? mediaMid;

  final int durationMs;

  /// 需要会员才能整曲播放。
  final bool payPlay;

  /// 封面直链。QQ 的图是公网可访问的，和网易云一样直接当 coverId 存。
  String? get coverUrl {
    final mid = albumMid;
    if (mid == null || mid.isEmpty) return null;
    return 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$mid.jpg';
  }

  static QQSong? fromJson(Map<String, dynamic> json) {
    final mid = (json['mid'] ?? json['songmid']) as String?;
    if (mid == null || mid.isEmpty) return null;

    // 歌手：musicu 用 singer，搜索用 singer 或 singername。
    final singerList = (json['singer'] as List?) ?? const [];
    // 把 name 和 mid 成对留住：歌手头像要靠 mid 拼
    // （`T001R500x500M000{mid}.jpg`，和专辑图 T002 同一套）。只留 artists
    // 那串拼好的名字是不够的 —— 多歌手时按名字匹配上了第二位，却只能拿到
    // 第一位的 mid，头像就会张冠李戴。
    final singers = <({String name, String mid})>[];
    for (final raw in singerList.whereType<Map>()) {
      final n = raw['name'];
      final m = raw['mid'];
      if (n is String && n.isNotEmpty && m is String && m.isNotEmpty) {
        singers.add((name: n, mid: m));
      }
    }
    var artists = singerList
        .whereType<Map>()
        .map((e) => e['name'])
        .whereType<String>()
        .where((n) => n.isNotEmpty)
        .join(' / ');
    if (artists.isEmpty) {
      artists = (json['singername'] as String?) ?? '';
    }

    final albumJson = json['album'] as Map?;
    final albumName =
        (albumJson?['name'] as String?) ?? (json['albumname'] as String?) ?? '';
    final albumMid =
        (albumJson?['mid'] as String?) ?? (json['albummid'] as String?);

    // 时长：musicu 是 interval（秒），搜索是 interval 或 duration（秒）。
    final seconds =
        (json['interval'] as int?) ?? (json['duration'] as int?) ?? 0;

    // 付费标记：pay.pay_play=1 表示整曲要会员。
    final pay = json['pay'] as Map?;
    final payPlay =
        (pay?['pay_play'] as int?) == 1 || (json['pay_play'] as int?) == 1;

    return QQSong(
      mid: mid,
      name: (json['name'] ?? json['songname']) as String? ?? '',
      artists: artists,
      singers: singers,
      album: albumName,
      albumMid: (albumMid != null && albumMid.isEmpty) ? null : albumMid,
      mediaMid: (json['file'] as Map?)?['media_mid'] as String?,
      durationMs: seconds * 1000,
      payPlay: payPlay,
    );
  }
}

/// QQ 歌单 / 榜单。
class QQPlaylist {
  const QQPlaylist({
    required this.id,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
    this.dirId,
  });

  final int id;
  final String name;
  final String? coverUrl;
  final int trackCount;

  /// 用户歌单才有的目录 id。`201` 是「我喜欢」那张特殊歌单。
  /// 推荐歌单没有这个字段，为 null。
  final int? dirId;
}
