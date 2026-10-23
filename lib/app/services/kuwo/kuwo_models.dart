/// 酷我一首歌的最小模型。
class KuwoSong {
  const KuwoSong({
    required this.rid,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    required this.coverUrl,
    required this.isVip,
  });

  /// 酷我主键（数字，字符串存）。
  final String rid;
  final String name;

  /// 歌手，`/` 分隔（已把酷我的 `&` 归一）。
  final String artists;
  final String album;
  final int durationMs;

  /// 完整 http 封面地址（酷我 www 接口直接给全链）。
  final String? coverUrl;
  final bool isVip;

  /// 从酷我 www 接口的一条记录解析（搜索 data.list / 榜单 data.musicList 同构）。
  static KuwoSong? fromJson(Map<String, dynamic> j) {
    final rid = (j['rid'] ?? j['musicrid'] ?? '').toString().replaceAll(
      RegExp(r'^MUSIC_'),
      '',
    );
    if (rid.isEmpty || rid == 'null') return null;
    final durSec = j['duration'] is int
        ? j['duration'] as int
        : int.tryParse('${j['duration'] ?? ''}') ?? 0;
    final artist = (j['artist'] ?? '').toString().replaceAll('&', ' / ').trim();
    return KuwoSong(
      rid: rid,
      name: (j['name'] ?? '').toString().trim(),
      artists: artist,
      album: (j['album'] ?? '').toString().trim(),
      durationMs: durSec * 1000,
      coverUrl: _pic(j),
      isVip: (j['isListenFee'] == 1 || j['pay'] == 1),
    );
  }

  static String? _pic(Map<String, dynamic> j) {
    for (final k in const ['pic', 'albumpic', 'web_albumpic_short', 'pic120']) {
      final v = j[k];
      if (v is String && v.startsWith('http')) return v;
    }
    return null;
  }
}
