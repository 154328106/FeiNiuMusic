import 'package:flutter/material.dart';

import '../../app/services/source/music_source_registry.dart';
import '../netease/netease_search_page.dart';
import 'search_page.dart';

/// 底部导航第 3 项「搜索」。
///
/// 搜的是**当前音乐源**：选飞牛就搜 NAS 曲库，选网易云就搜网易云。之前这里
/// 焊死了飞牛的搜索页，换到网易云后首页是网易云的内容、搜索却还在搜 NAS，
/// 对不上。两边的搜索页短期内不合流（飞牛那套从上到下吃 FeiNiuTrack 强
/// 类型），先在入口处按源分流。
class SearchTab extends StatelessWidget {
  const SearchTab({super.key});

  @override
  Widget build(BuildContext context) {
    final registry = MusicSourceRegistry.instance;
    return ValueListenableBuilder(
      valueListenable: registry.current,
      builder: (context, source, _) {
        if (source.id == 'netease') {
          // key 带上源 id：换源时强制重建，不会把上一个源的搜索结果留在屏幕上。
          return const NetEaseSearchPage(
            key: ValueKey('search-netease'),
            embedded: true,
          );
        }
        return const SearchPage(key: ValueKey('search-feiniu'));
      },
    );
  }
}
