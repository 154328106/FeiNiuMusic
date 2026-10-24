/// 咪咕一首歌的最小模型。
///
/// 咪咕一首歌有三个 id：`copyrightId`（版权 id，聚合/LX 的 mg 后端按它取址，
/// 也是我们编进 [SongEntity.id] 的主键）、`contentId`（内容 id，咪咕自家直连
/// 播放 `listenSong.do` 要用）、`id`（歌曲 id，基本用不上）。
class MiguSong {
  const MiguSong({
    required this.copyrightId,
    required this.contentId,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    required this.coverUrl,
    required this.isVip,
    this.lyricUrl,
  });

  /// 版权 id：主键，聚合/LX 的 mg 后端按它取址。
  final String copyrightId;

  /// 内容 id：咪咕自家 `listenSong.do` 直连播放要用（登录后才给 VIP 直链）。
  final String contentId;
  final String name;

  /// 歌手，`/` 分隔。
  final String artists;
  final String album;
  final int durationMs;

  /// 完整 http(s) 封面地址（咪咕 imgItems 直接给全链）。
  final String? coverUrl;
  final bool isVip;

  /// 歌词 .lrc 直链（search_all.do 直接给，存到实体上，歌词页直接拉）。
  final String? lyricUrl;

  /// 从咪咕 search_all.do 的一条记录解析（`songResultData.result[]` 的元素）。
  static MiguSong? fromJson(Map<String, dynamic> j) {
    final copyrightId = (j['copyrightId'] ?? '').toString().trim();
    final contentId = (j['contentId'] ?? '').toString().trim();
    // 没有 copyrightId 就取不了址，直接丢弃。
    if (copyrightId.isEmpty || copyrightId == 'null') return null;
    final name = (j['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return MiguSong(
      copyrightId: copyrightId,
      contentId: contentId,
      name: name,
      artists: _names(j['singers']),
      album: _albumName(j['albums']),
      durationMs: 0, // search_all.do 不给时长，播放页会用解析到的流时长。
      coverUrl: _cover(j['imgItems']),
      isVip: _vip(j['newRateFormats']),
      lyricUrl: () {
        final u = (j['lyricUrl'] ?? '').toString().trim();
        return u.startsWith('http') ? u : null;
      }(),
    );
  }

  /// 从咪咕榜单 `querycontentbyId.do` 的一条记录解析
  /// （`columnInfo.contents[].objectInfo`）。字段名和搜索不同：`songName`
  /// / `singer`(字符串) / `album`(字符串) / `albumImgs`(同 imgItems 三档) /
  /// `lrcUrl`。
  static MiguSong? fromChartJson(Map<String, dynamic> j) {
    final copyrightId = (j['copyrightId'] ?? '').toString().trim();
    final contentId = (j['contentId'] ?? '').toString().trim();
    if (copyrightId.isEmpty || copyrightId == 'null') return null;
    final name = (j['songName'] ?? j['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final singer = (j['singer'] ?? '')
        .toString()
        .replaceAll(RegExp(r'[、，]'), ' / ')
        .trim();
    return MiguSong(
      copyrightId: copyrightId,
      contentId: contentId,
      name: name,
      artists: singer,
      album: (j['album'] ?? '').toString().trim(),
      durationMs: 0,
      coverUrl: _cover(j['albumImgs']),
      isVip: _vip(j['newRateFormats']),
      lyricUrl: () {
        final u = (j['lrcUrl'] ?? '').toString().trim();
        return u.startsWith('http') ? u : null;
      }(),
    );
  }

  /// singers 可能是单对象 `{id,name}`，也可能是数组；都归一成 `/` 分隔。
  static String _names(dynamic singers) {
    if (singers is List) {
      final names = <String>[
        for (final s in singers)
          if (s is Map && (s['name'] ?? '').toString().trim().isNotEmpty)
            (s['name']).toString().trim(),
      ];
      return names.join(' / ');
    }
    if (singers is Map) return (singers['name'] ?? '').toString().trim();
    return '';
  }

  static String _albumName(dynamic albums) {
    if (albums is List && albums.isNotEmpty && albums.first is Map) {
      return (albums.first['name'] ?? '').toString().trim();
    }
    if (albums is Map) return (albums['name'] ?? '').toString().trim();
    return '';
  }

  /// imgItems 形如 `[{imgSizeType:"01",img:...},{"02"...},{"03"...}]`，
  /// 取尺寸最大的那档（03 > 02 > 01）。
  static String? _cover(dynamic imgItems) {
    if (imgItems is! List || imgItems.isEmpty) return null;
    String? best;
    var bestRank = -1;
    for (final item in imgItems) {
      if (item is! Map) continue;
      final img = (item['img'] ?? '').toString().trim();
      if (img.isEmpty || !img.startsWith('http')) continue;
      final rank = int.tryParse('${item['imgSizeType'] ?? ''}') ?? 0;
      if (rank >= bestRank) {
        bestRank = rank;
        best = img;
      }
    }
    return best;
  }

  /// newRateFormats 里但凡有一档标了 `vip` 就算会员曲（免登录多半只给试听）。
  static bool _vip(dynamic rates) {
    if (rates is! List) return false;
    for (final r in rates) {
      if (r is! Map) continue;
      final tags = r['showTag'];
      if (tags is List && tags.any((t) => '$t'.toLowerCase() == 'vip')) {
        return true;
      }
    }
    return false;
  }
}
