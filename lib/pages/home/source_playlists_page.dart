import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/router/app_page_route.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/source/music_source.dart';
import '../../components/index.dart';
import 'source_feed_page.dart';

/// 非飞牛源的歌单/榜单列表（两列封面网格）。
///
/// 飞牛的歌单页带创建、改名、排序一整套自家能力，换源后照搬不过来；这里只做
/// 「列出来、点进去能播」。数据由调用方给一个 loader，所以「我的歌单」和
/// 「排行榜」共用这一个页面 —— 对网易云来说榜单本来也就是歌单。
class SourcePlaylistsPage extends StatefulWidget {
  const SourcePlaylistsPage({
    super.key,
    required this.title,
    required this.loader,
    this.emptyHint,
    this.categoriesLoader,
    this.categoryLoader,
  });

  final String title;
  final Future<List<SourcePlaylist>> Function() loader;

  /// 空列表时的说明。多半是「没登录」。
  final String? emptyHint;

  /// 分类名列表。给了它（且给了 [categoryLoader]）才会在顶部显示分类条。
  ///
  /// 两个都是可选的：酷狗/QQ 的歌单、排行榜、歌手那几个入口都不传，
  /// 页面行为和以前完全一样。
  final Future<List<String>> Function()? categoriesLoader;

  /// 按分类取歌单。选中某个分类时用它，选「全部」时仍走 [loader]。
  final Future<List<SourcePlaylist>> Function(String cat)? categoryLoader;

  @override
  State<SourcePlaylistsPage> createState() => _SourcePlaylistsPageState();
}

class _SourcePlaylistsPageState extends State<SourcePlaylistsPage> {
  List<SourcePlaylist> _items = const [];
  bool _loading = true;

  /// 分类条。空 = 不显示（没传 loader，或者取分类失败）。
  List<String> _categories = const [];

  /// 当前选中的分类。null = 「全部」，走 [SourcePlaylistsPage.loader]。
  String? _cat;

  bool get _hasCategories =>
      widget.categoriesLoader != null && widget.categoryLoader != null;

  @override
  void initState() {
    super.initState();
    _load();
    if (_hasCategories) _loadCategories();
  }

  /// 取分类名。失败就不显示分类条 —— 它是加分项，不该把歌单列表一起拖垮。
  Future<void> _loadCategories() async {
    try {
      final cats = await widget.categoriesLoader!();
      if (!mounted || cats.isEmpty) return;
      setState(() => _categories = cats);
    } catch (e) {
      debugPrint('[SourcePlaylistsPage] 取分类失败：$e');
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cat = _cat;
    final items = cat == null
        ? await widget.loader()
        : await widget.categoryLoader!(cat);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _selectCategory(String? cat) {
    if (_cat == cat) return;
    setState(() => _cat = cat);
    _load();
  }

  void _open(SourcePlaylist playlist) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => SourceFeedPage(playlistId: playlist.id, title: playlist.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: AppTopBar(
        title: widget.title,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _categories.isEmpty
          ? _buildBody(scheme)
          : Column(
              children: [
                _buildCategoryBar(scheme),
                Expanded(child: _buildBody(scheme)),
              ],
            ),
    );
  }

  /// 顶部分类条。横向滚动的一排 chip，第一个是「全部」。
  ///
  /// 网易云有 70 个分类，没法一屏铺开，也不值得为「先看看效果」做成分组
  /// 网格 —— 横滚一排正是网易云自己的做法。真要按语种/风格/场景分组，
  /// `/api/playlist/catalogue` 的响应里有 `categories`（组名）和每项的
  /// `category`（组 id），到时候按它分。
  Widget _buildCategoryBar(ColorScheme scheme) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: _categories.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final cat = i == 0 ? null : _categories[i - 1];
          final selected = _cat == cat;
          return ChoiceChip(
            label: Text(cat ?? '全部'),
            selected: selected,
            // 加载中不让切，否则连点几下会有好几发请求在飞，最后哪个先回
            // 显示哪个 —— 列表和选中的 chip 对不上。
            onSelected: _loading ? null : (_) => _selectCategory(cat),
            showCheckmark: false,
            labelStyle: TextStyle(
              fontSize: 13,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            selectedColor: scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
          );
        },
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyHint ?? '${widget.title}暂无内容',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        AppPageScaffold.scrollableBottomPadding(context),
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        // 封面是正方形，下面留两行文字的位置。
        childAspectRatio: 0.78,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) => _tile(_items[index], scheme),
    );
  }

  Widget _tile(SourcePlaylist playlist, ColorScheme scheme) {
    final coverId = playlist.coverId;
    return GestureDetector(
      onTap: () => _open(playlist),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox.expand(
                child: (coverId == null || coverId.isEmpty)
                    ? ColoredBox(color: scheme.surfaceContainerHighest)
                    : CachedNetworkImage(
                        // 与 ArtworkWidget 同一套判断：非飞牛的源存的就是
                        // 公网直链，直接用，也不能带飞牛的鉴权头。
                        imageUrl: coverId.startsWith('http')
                            ? coverId
                            : FeiNiuApiClient.instance.coverUrl(
                                coverId,
                                size: FeiNiuApiClient.coverRequestSize,
                              ),
                        httpHeaders: coverId.startsWith('http')
                            ? null
                            : FeiNiuApiClient.imageAuthHeaders(),
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            ColoredBox(color: scheme.surfaceContainerHighest),
                        errorWidget: (_, _, _) =>
                            ColoredBox(color: scheme.surfaceContainerHighest),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          if (playlist.trackCount > 0)
            Text(
              '${playlist.trackCount} 首',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
