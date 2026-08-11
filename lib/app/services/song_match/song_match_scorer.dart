import '../plugin/plugin_result_parser.dart';

/// 搜索结果合并排序工具（Lyrico 多源「综合」展示用）。
///
/// 综合 tab 把多源结果合并，按**插件源顺序**（插件列表排序）分组排列；
/// 同源内保持插件返回的原始顺序。

class SongMatchScorer {
  /// 把多源结果合并为「综合」列表：按插件源顺序分组，同源内保持插件返回顺序。
  ///
  /// [sourceOrder] 为源 id 的列表顺序（插件列表排序），决定各源的先后；
  /// 未知源（不在 [sourceOrder] 中）排在最后，按出现顺序保持。
  static List<SongMatchResult> mergeRanked(
    List<List<SongMatchResult>> groups, {
    List<String> sourceOrder = const [],
  }) {
    final sourceIndex = <String, int>{
      for (var i = 0; i < sourceOrder.length; i++) sourceOrder[i]: i,
    };
    final flat = groups.expand((g) => g).toList();
    flat.sort((a, b) {
      // 按插件源顺序升序（源靠前优先；未知源排最后）
      final ia = sourceIndex[a.pluginId] ?? 0x7fffffff;
      final ib = sourceIndex[b.pluginId] ?? 0x7fffffff;
      if (ia != ib) return ia.compareTo(ib);
      // 同源：保持插件返回的原始顺序（稳定排序，不动相对次序）
      return 0;
    });
    return flat;
  }
}
