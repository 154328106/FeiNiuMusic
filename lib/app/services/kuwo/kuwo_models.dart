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
    final rid =
        (j['rid'] ?? j['musicrid'] ?? j['MUSICRID'] ?? j['id'] ?? '')
            .toString()
            .replaceAll(RegExp(r'^MUSIC_'), '');
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
    for (final k in const [
      'pic',
      'albumpic',
      'web_albumpic_short',
      'hts_MVPIC',
      'pic120',
    ]) {
      final v = j[k];
      if (v is String && v.isNotEmpty) {
        if (v.startsWith('http')) return upsize(v);
        // kbangserver 等给的是相对路径（"120/xx/xx/xxx.jpg"），拼成完整大图。
        final rel = v
            .replaceFirst(RegExp(r'^/'), '')
            .replaceFirst(RegExp(r'^\d+/'), '500/');
        return 'https://img1.kuwo.cn/star/albumcover/$rel';
      }
    }
    return null;
  }

  /// 把酷我封面升到大图：路径里 `/albumcover/<尺寸>/` 的尺寸段换成 500，
  /// 否则接口默认给 120 的缩略图，放大后很糊。
  static String upsize(String url) =>
      url.replaceFirst(RegExp(r'/albumcover/\d+/'), '/albumcover/500/');
}
