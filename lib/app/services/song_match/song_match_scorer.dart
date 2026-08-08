import '../plugin/plugin_result_parser.dart';

/// 搜索结果匹配度排序工具（Lyrico 多源「综合」展示用）。
///
/// 综合 tab 把多源结果合并，按**名字匹配度**降序排列；匹配度相同时按
/// **源顺序**（插件列表顺序）靠前的优先。

/// 给候选打分：与搜索关键词的匹配程度。
///
/// 分数越高越匹配。维度：
/// - 标题完全等于关键词 → +100；
/// - 标题包含关键词 → +80；
/// - 关键词包含标题 → +60；
/// - 标题与关键词有字符重叠 → +40；
/// - 歌手/专辑包含关键词 → 各 +10。
class SongMatchScorer {
  /// 归一化：小写、去除空白。
  static String _norm(String s) => s.trim().toLowerCase();

  /// 计算单个候选对 [keyword] 的匹配度分数（0~100+）。
  static int score(SongMatchResult candidate, String keyword) {
    final kw = _norm(keyword);
    if (kw.isEmpty) return 0;
    final title = _norm(candidate.title);
    final artist = _norm(candidate.artist);
    final album = _norm(candidate.album);

    var score = 0;
    if (title == kw) {
      score += 100;
    } else if (title.isNotEmpty && title.contains(kw)) {
      score += 80;
    } else if (kw.contains(title) && title.isNotEmpty) {
      score += 60;
    } else if (title.isNotEmpty && _hasOverlap(title, kw)) {
      // 部分字符重叠（简单启发式：任一字命中）
      score += 40;
    }
    if (artist.isNotEmpty && artist.contains(kw)) score += 10;
    if (album.isNotEmpty && album.contains(kw)) score += 10;
    return score;
  }

  /// 标题与关键词是否有任意字符重叠（中文逐字、英文按整词）。
  static bool _hasOverlap(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    for (var i = 0; i < b.length; i++) {
      if (a.contains(b[i])) return true;
    }
    return false;
  }

  /// 把多源结果合并为「综合」列表：按匹配度降序，同分按 [sourceOrder] 靠前优先。
  ///
  /// [sourceOrder] 为源 id 的列表顺序（插件列表排序），决定同分时的优先级。
  static List<SongMatchResult> mergeRanked(
    List<List<SongMatchResult>> groups,
    String keyword, {
    List<String> sourceOrder = const [],
  }) {
    final sourceIndex = <String, int>{
      for (var i = 0; i < sourceOrder.length; i++) sourceOrder[i]: i,
    };
    final flat = groups.expand((g) => g).toList();
    flat.sort((a, b) {
      final sa = score(a, keyword);
      final sb = score(b, keyword);
      if (sa != sb) return sb.compareTo(sa); // 匹配度降序
      // 同分：源顺序靠前优先（未知源排最后）
      final ia = sourceIndex[a.pluginId] ?? 0x7fffffff;
      final ib = sourceIndex[b.pluginId] ?? 0x7fffffff;
      if (ia != ib) return ia.compareTo(ib);
      return 0;
    });
    return flat;
  }
}
