import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../../app/services/db/dao/download_dao.dart';
import '../../app/services/download/download_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_source.dart';
import '../../components/index.dart';

/// 「本地」页：跨源汇总已下载的歌曲，支持播放、全部播放、删除。
///
/// 播放走 [PlayerService.playQueue] 即可 —— 已下载歌曲在
/// `PlayerService._sourceForSong` 顶部会直接命中本地文件（离线、零流量），
/// 不需要像在线列表那样预解析地址。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final _player = PlayerService.instance;

  List<DownloadRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // 下载完成/删除后自动刷新列表。
    DownloadService.instance.revision.addListener(_load);
  }

  @override
  void dispose() {
    DownloadService.instance.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final records = await DownloadService.instance.all();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _playAll() async {
    if (_records.isEmpty) return;
    await _player.playQueue(_records.map((r) => r.song).toList(), 0);
  }

  Future<void> _play(int index) async {
    await _player.playQueue(_records.map((r) => r.song).toList(), index);
  }

  Future<void> _confirmDelete(DownloadRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('确定删除本地文件「${record.song.title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DownloadService.instance.delete(record.song.id);
    // revision 监听会触发 _load，这里不用手动刷新。
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: AppTopBar(
        title: '本地',
        actions: [
          IconButton(
            tooltip: '下载目录',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: _showFolder,
          ),
          IconButton(
            tooltip: '全部播放',
            icon: const Icon(Icons.play_circle_fill_rounded),
            onPressed: _records.isEmpty ? null : _playAll,
          ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  /// 「下载目录」：显示在哪儿找，可复制完整路径。
  ///
  /// iOS 的路径是 `/var/mobile/Containers/.../Documents/downloads`，看着像沙盒
  /// 其实配合 Info.plist 的 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace
  /// 已在「文件」App 里暴露，所以给的是导航指引而不是那串没法点的路径；iOS 也
  /// 没法用 url_launcher 打开目录，那个按钮只在安卓给。
  Future<void> _showFolder() async {
    final path = await DownloadService.instance.downloadsDirPath();
    if (!mounted) return;
    final isIOS = Platform.isIOS;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isIOS)
              const Text(
                '在「文件」App 里打开：\n'
                '我的 iPhone → 飞牛音乐 → downloads',
                style: TextStyle(fontSize: 14, height: 1.6),
              ),
            if (isIOS) const SizedBox(height: 10),
            SelectableText(
              path,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              Navigator.pop(ctx);
              AppToast.show(context, '路径已复制');
            },
            child: const Text('复制路径'),
          ),
          if (!isIOS)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final ok = await launchUrl(
                    Uri.directory(path),
                    mode: LaunchMode.externalApplication,
                  );
                  if (!ok && mounted) {
                    AppToast.show(context, '打不开，请到文件管理器手动进入该路径');
                  }
                } catch (_) {
                  if (mounted) {
                    AppToast.show(context, '打不开，请到文件管理器手动进入该路径');
                  }
                }
              },
              child: const Text('用文件管理器打开'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_done_rounded,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有下载的歌曲\n在歌曲详情里点「下载到本地」',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        AppPageScaffold.scrollableBottomPadding(context),
      ),
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final record = _records[index];
        final song = record.song;
        return AppContentRow(
          isLast: index == _records.length - 1,
          horizontalInset: 10,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: ArtworkWidget(song: song, size: 48, borderRadius: 8),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${song.artistDisplayName} · ${_sourceLabel(record.source)} · '
              '${_formatSize(record.fileSize)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _confirmDelete(record),
            ),
            onTap: () => _play(index),
          ),
        );
      },
    );
  }

  static String _sourceLabel(SongSource source) => switch (source) {
    SongSource.feiniu => '飞牛',
    SongSource.netease => '网易',
    SongSource.qq => 'QQ',
    SongSource.kugou => '酷狗',
    SongSource.kuwo => '酷我',
    SongSource.migu => '咪咕',
  };

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 || unit == 0 ? 0 : 1)}'
        '${units[unit]}';
  }
}
