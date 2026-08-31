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
  });

  final String title;
  final Future<List<SourcePlaylist>> Function() loader;

  /// 空列表时的说明。多半是「没登录」。
  final String? emptyHint;

  @override
  State<SourcePlaylistsPage> createState() => _SourcePlaylistsPageState();
}

class _SourcePlaylistsPageState extends State<SourcePlaylistsPage> {
  List<SourcePlaylist> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await widget.loader();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
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
      body: _buildBody(scheme),
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
