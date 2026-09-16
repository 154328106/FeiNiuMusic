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

  /// 分类，按组给（组名 → 该组的分类名）。给了它（且给了 [categoryLoader]）
  /// 才会在右上角出现筛选按钮。
  ///
  /// 两个都是可选的：酷狗/QQ 的歌单、排行榜、歌手那几个入口都不传，
  /// 页面行为和以前完全一样。
  final Future<Map<String, List<String>>> Function()? categoriesLoader;

  /// 按分类取歌单。选中某个分类时用它，选「全部」时仍走 [loader]。
  final Future<List<SourcePlaylist>> Function(String cat)? categoryLoader;

  @override
  State<SourcePlaylistsPage> createState() => _SourcePlaylistsPageState();
}

class _SourcePlaylistsPageState extends State<SourcePlaylistsPage> {
  List<SourcePlaylist> _items = const [];
  bool _loading = true;

  /// 分类，按组。空 = 不显示筛选按钮（没传 loader，或者取分类失败）。
  Map<String, List<String>> _categories = const {};

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
      final groups = await widget.categoriesLoader!();
      if (!mounted || groups.isEmpty) return;
      setState(() => _categories = groups);
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
    final cat = _cat;
    return AppPageScaffold(
      appBar: AppTopBar(
        // 选了分类就写在标题里 —— 筛选态必须一眼看得见，否则翻着翻着
        // 忘了自己还在某个分类下，会以为「歌单怎么变少了」。
        title: cat == null ? widget.title : '${widget.title} · $cat',
        actions: [
          if (_categories.isNotEmpty)
            IconButton(
              tooltip: '分类',
              icon: Icon(
                cat == null
                    ? Icons.filter_list_rounded
                    : Icons.filter_list_off_rounded,
                color: cat == null ? null : scheme.primary,
              ),
              onPressed: _loading ? null : _pickCategory,
            ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  /// 弹出分类选择。
  ///
  /// 做成弹出层而不是顶部横滑条：70 个分类横滑要划十几屏才看得完，
  /// 而且没有结构。这里按接口给的组分段（热门 / 语种 / 风格 / 场景 /
  /// 情感 / 主题），一屏能扫完大半。
  Future<void> _pickCategory() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // 不占满整屏：留一截能看见下面的列表，知道自己是在筛选而不是换了页面。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 「全部」单独放最上面，它不属于任何组。
                _catChip(sheetContext, null, scheme),
                for (final entry in _categories.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final name in entry.value)
                        _catChip(sheetContext, name, scheme),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    // 关掉弹层等于放弃选择（picked 为 null 且没点过「全部」）。
    // 「全部」返回的是哨兵字符串，见 _catChip。
    if (picked == null) return;
    _selectCategory(picked == _allSentinel ? null : picked);
  }

  /// 「全部」的哨兵值。
  ///
  /// `showModalBottomSheet` 关闭时也返回 null，没法用 null 表示「选了全部」
  /// —— 那样点「全部」和划走关掉就分不开了。
  static const String _allSentinel = r'\__all__';

  Widget _catChip(BuildContext sheetContext, String? cat, ColorScheme scheme) {
    final selected = _cat == cat;
    return ChoiceChip(
      label: Text(cat ?? '全部'),
      selected: selected,
      onSelected: (_) => Navigator.of(sheetContext).pop(cat ?? _allSentinel),
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
