import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/services/lxscript/lx_source_manager.dart';
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

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js'],
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final text = await File(path).readAsString();
      await _doImport(text);
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
      await _doImport(controller.text);
    }
  }

  Future<void> _doImport(String text) async {
    setState(() => _busy = true);
    try {
      final meta = await _mgr.import(text);
      if (!mounted) return;
      if (meta == null) {
        AppToast.show(
          context,
          '导入失败：脚本未通过加载（格式不符或未声明支持的源）',
          type: ToastType.error,
        );
      } else {
        AppToast.show(
          context,
          '已导入「${meta.name}」，支持：${meta.sources.join('/')}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
        title: 'LX 脚本音源',
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            icon: const Icon(Icons.add_rounded),
            onSelected: (v) {
              if (v == 'file') _importFromFile();
              if (v == 'text') _importFromText();
            },
            itemBuilder: (_) => const [
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
                    '脚本作为官方与内置音源都取不到地址时的补充；按脚本声明的平台匹配。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                for (final s in sources)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: SwitchListTile(
                      value: s.enabled,
                      onChanged: (v) => _mgr.setEnabled(s.id, v),
                      title: Text(s.name),
                      subtitle: Text(
                        s.sources.isEmpty
                            ? '未声明支持的源'
                            : '支持：${s.sources.join(' / ')}',
                      ),
                      secondary: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => _confirmRemove(s),
                      ),
                    ),
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
