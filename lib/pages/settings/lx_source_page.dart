import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/services/lxscript/lx_source_manager.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_source.dart';
import '../../components/index.dart';

/// LX（洛雪）脚本音源管理页：导入 / 启停 / 删除。
///
/// 脚本按洛雪自定义源协议写（`globalThis.lx`），导入后由
/// [LxSourceManager] 在应用内 JS 引擎里跑，解灰链按平台代号调它取址。
class LxSourcePage extends StatefulWidget {
  const LxSourcePage({super.key});

  @override
  State<LxSourcePage> createState() => _LxSourcePageState();
}

class _LxSourcePageState extends State<LxSourcePage> {
  final _mgr = LxSourceManager.instance;
  bool _busy = false;
  bool _testing = false;

  /// 最近一次测试：歌名 · 歌手、平台中文名、每个脚本一行；[testing] 是正在
  /// 问的那个脚本（边测边出，测完为 null）。
  ({String song, String platform, List<LxTestRow> rows, String? testing})?
  _testResult;

  @override
  void initState() {
    super.initState();
    _mgr.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _mgr.revision.addListener(_onChanged);
  }

  @override
  void dispose() {
    _mgr.revision.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 测试：拿「当前正在播放的歌」逐个问启用的脚本（真实合法 id，比硬编码
  /// 测试曲可靠）。没在播或播的是飞牛歌时给出指引。
  Future<void> _test() async {
    final song = PlayerService.instance.currentSong.value;
    if (song == null) {
      AppToast.show(context, '先在任意源（网易/QQ/酷狗）播一首歌，再回来测试');
      return;
    }
    final source = SongSource.fromSongId(song.id);
    String? platform;
    String? id;
    switch (source) {
      case SongSource.netease:
        platform = 'wy';
        id = '${SongSource.decodeNetease(song.id)}';
      case SongSource.qq:
        platform = 'tx';
        id = SongSource.decodeQQ(song.id);
      case SongSource.kugou:
        platform = 'kg';
        id = SongSource.decodeKugou(song.id);
      case SongSource.kuwo:
        platform = 'kw';
        id = SongSource.decodeKuwo(song.id);
      case SongSource.migu:
        platform = 'mg';
        id = SongSource.decodeMigu(song.id);
      case SongSource.feiniu:
        AppToast.show(context, '当前播的是飞牛本地歌，音源脚本用不上；换一首在线歌再测');
        return;
    }
    if (id == null || id.isEmpty) {
      AppToast.show(context, '取不到当前歌的来源 id', type: ToastType.error);
      return;
    }
    final singer = song.artistDisplayName;
    final songText = singer.isEmpty ? song.title : '${song.title} - $singer';
    final platformText = LxSourceManager.platformNames[platform] ?? platform;
    setState(() {
      _testing = true;
      _testResult = (
        song: songText,
        platform: platformText,
        rows: const <LxTestRow>[],
        testing: '…',
      );
    });
    try {
      // 每测完一个脚本就先显示出来，不用干等全部测完。
      final rows = await _mgr.testRows(
        platform: platform,
        songId: id,
        name: song.title,
        singer: singer,
        onProgress: (rows, testing) {
          if (!mounted) return;
          setState(
            () => _testResult = (
              song: songText,
              platform: platformText,
              rows: rows,
              testing: testing,
            ),
          );
        },
      );
      if (mounted) {
        setState(
          () => _testResult = (
            song: songText,
            platform: platformText,
            rows: rows,
            testing: null,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 选文件：可以一次多选几个 .js，逐个导入。
  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js'],
        allowMultiple: true,
      );
      final paths = [
        for (final f in result?.files ?? const <PlatformFile>[])
          if (f.path != null) f.path!,
      ];
      if (paths.isEmpty) return;
      await _doImportAll([
        for (final p in paths)
          (
            label: p.split(RegExp(r'[\/]')).last,
            loader: () async => _mgr.import(await File(p).readAsString()),
          ),
      ]);
    } catch (e) {
      if (mounted) AppToast.show(context, '读取文件失败：$e', type: ToastType.error);
    }
  }

  Future<void> _importFromText() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴脚本内容'),
        content: TextField(
          controller: controller,
          minLines: 6,
          maxLines: 14,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: '粘贴洛雪(LX)音源脚本的完整 .js 内容',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      await _doImportAll([
        (label: '粘贴的脚本', loader: () => _mgr.import(controller.text)),
      ]);
    }
  }

  /// 链接：一行一个（空格、逗号分隔也认），一次导入多个源。
  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从链接导入'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 8,
          autocorrect: false,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText:
                '粘贴音源订阅链接，多个就一行一个，例如\n'
                'https://c.wwwweb.top/script/lxmusic?key=...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final urls = controller.text
        .split(RegExp(r'[\s,，]+'))
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    if (urls.isEmpty) return;
    await _doImportAll([
      for (final u in urls) (label: u, loader: () => _mgr.importFromUrl(u)),
    ]);
  }

  /// 逐个导入，最后汇总一条提示。一个失败不影响后面的。
  Future<void> _doImportAll(
    List<({String label, Future<LxSource?> Function() loader})> jobs,
  ) async {
    setState(() => _busy = true);
    final ok = <LxSource>[];
    final failed = <String>[];
    try {
      for (final job in jobs) {
        try {
          final meta = await job.loader();
          if (meta == null) {
            failed.add(job.label);
          } else {
            ok.add(meta);
          }
        } catch (_) {
          failed.add(job.label);
        }
      }
      if (!mounted) return;
      if (jobs.length == 1) {
        if (ok.isEmpty) {
          AppToast.show(
            context,
            '导入失败：脚本未通过加载（格式不符或未声明支持的源）',
            type: ToastType.error,
          );
        } else {
          final m = ok.first;
          AppToast.show(context, '已导入「${m.name}」，支持：${m.sources.join('/')}');
        }
        return;
      }
      final names = ok.map((m) => m.name).join('、');
      AppToast.show(
        context,
        failed.isEmpty
            ? '已导入 ${ok.length} 个：$names'
            : '导入成功 ${ok.length} 个，失败 ${failed.length} 个'
                  '${ok.isEmpty ? '' : '（$names）'}',
        type: ok.isEmpty ? ToastType.error : ToastType.success,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameSource(LxSource s) async {
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名脚本音源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '给这个音源起个名字'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await _mgr.renameSource(s.id, name);
    }
  }

  Future<void> _confirmRemove(LxSource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除脚本音源'),
        content: Text('确定删除「${s.name}」？'),
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
    if (ok == true) await _mgr.remove(s.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sources = _mgr.list();
    return AppPageScaffold(
      appBar: AppTopBar(
        title: '音源脚本',
        actions: [
          IconButton(
            tooltip: '测试（用当前播放的歌）',
            icon: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find_rounded),
            onPressed: (_testing || sources.isEmpty) ? null : _test,
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            icon: const Icon(Icons.add_rounded),
            onSelected: (v) {
              if (v == 'url') _importFromUrl();
              if (v == 'file') _importFromFile();
              if (v == 'text') _importFromText();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'url', child: Text('从链接导入')),
              PopupMenuItem(value: 'file', child: Text('从文件导入 .js')),
              PopupMenuItem(value: 'text', child: Text('粘贴文本导入')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          if (sources.isEmpty)
            _buildEmpty(scheme)
          else
            ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                AppPageScaffold.scrollableBottomPadding(context),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    '脚本作为官方与内置音源都取不到地址时的补充；按脚本声明的平台匹配。'
                    '右上角「测试」会拿当前正在播放的歌逐个问脚本，看能否取到地址。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_testResult != null)
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    color: scheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.science_rounded,
                                size: 16,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                '测试结果',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const Spacer(),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () =>
                                    setState(() => _testResult = null),
                              ),
                            ],
                          ),
                          _TestResultView(result: _testResult!),
                        ],
                      ),
                    ),
                  ),
                if (sources.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: Text(
                      '按从上到下的顺序问，前面的拿到就不再往下问。长按卡片可以拖动排序。'
                      '某个平台上次是哪个脚本给出地址的，下次同平台会先问它；它没给出来，'
                      '就按这个顺序往下接力。',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                // 长按拖动排序（2026-11-05）。嵌在外层 ListView 里，自己不滚动。
                // 不用默认拖动把手：桌面端把手会压在开关上；统一改成长按卡片拖。
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: sources.length,
                  onReorderItem: (oldIndex, newIndex) =>
                      _mgr.move(sources[oldIndex].id, newIndex),
                  itemBuilder: (context, index) {
                    final s = sources[index];
                    final last = sources.length - 1;
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(s.id),
                      index: index,
                      child: Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: SwitchListTile(
                          value: s.enabled,
                          onChanged: (v) => _mgr.setEnabled(s.id, v),
                          title: Text(s.name),
                          subtitle: Text(
                            [
                              if (sources.length > 1) '第 ${index + 1} 个问',
                              s.sources.isEmpty
                                  ? '未声明支持的源'
                                  : '支持：${s.sources.join(' / ')}',
                            ].join(' · '),
                          ),
                          secondary: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert_rounded),
                            onSelected: (v) {
                              if (v == 'top') _mgr.move(s.id, 0);
                              if (v == 'up') _mgr.move(s.id, index - 1);
                              if (v == 'down') _mgr.move(s.id, index + 1);
                              if (v == 'rename') _renameSource(s);
                              if (v == 'delete') _confirmRemove(s);
                            },
                            itemBuilder: (_) => [
                              if (index > 0)
                                const PopupMenuItem(
                                  value: 'top',
                                  child: Text('移到最前'),
                                ),
                              if (index > 0)
                                const PopupMenuItem(
                                  value: 'up',
                                  child: Text('上移'),
                                ),
                              if (index < last)
                                const PopupMenuItem(
                                  value: 'down',
                                  child: Text('下移'),
                                ),
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('删除'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          if (_busy)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.extension_rounded,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有导入脚本音源\n右上角「+」从文件或粘贴导入洛雪(LX)格式的 .js',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 测试结果：歌曲、平台，然后每个脚本一行「名字 · 格式 · 大小 · 用时 · ✅/❌」。
class _TestResultView extends StatelessWidget {
  const _TestResultView({required this.result});

  final ({String song, String platform, List<LxTestRow> rows, String? testing})
  result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const base = TextStyle(fontSize: 13, height: 1.5);
    final dim = base.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('歌曲：${result.song}', style: base),
        Text('平台：${result.platform}', style: base),
        const SizedBox(height: 4),
        const Text('详情：', style: base),
        if (result.rows.isEmpty && result.testing == null)
          Text('没有启用的脚本', style: dim)
        else
          for (final r in result.rows) _row(r, base, dim),
        if (result.testing != null)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.testing == '…' ? '准备中…' : '正在问 ${result.testing}…',
                    style: dim,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(LxTestRow r, TextStyle base, TextStyle dim) {
    final size = r.size > 0 ? '${(r.size / 1048576).toStringAsFixed(1)}MB' : '';
    final ms = r.ms == null ? '' : '${r.ms}ms';
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.name,
                  style: base,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: 44, child: Text(r.format ?? '', style: base)),
              SizedBox(
                width: 56,
                child: Text(size, style: base, textAlign: TextAlign.right),
              ),
              SizedBox(
                width: 62,
                child: Text(ms, style: base, textAlign: TextAlign.right),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  r.ok ? '✅' : '❌',
                  style: base,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (r.note.isNotEmpty)
            Text(
              r.note,
              style: dim.copyWith(fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
