import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/plugin/plugin_importer.dart';
import '../../app/services/plugin/plugin_manifest.dart';
import '../../app/services/plugin/plugin_store.dart';
import '../../components/index.dart';

/// 数据源维护页：Lyrico 搜索源插件管理。
///
/// - 列表展示已安装插件（图标/名称/版本/能力/启用开关）；
/// - 导入插件 zip（inspectZip 识别候选 → 确认安装）；
/// - 配置插件（configFields 声明式表单）；
/// - 卸载插件。
class DataSourcePage extends StatefulWidget {
  const DataSourcePage({super.key});

  @override
  State<DataSourcePage> createState() => _DataSourcePageState();
}

class _DataSourcePageState extends State<DataSourcePage> with SignalsMixin {
  late final _plugins = createSignal<List<InstalledPlugin>>(const []);
  late final _loading = createSignal(true);
  late final _importing = createSignal(false);

  final PluginStore _store = PluginStore.instance;
  final PluginImporter _importer = PluginImporter();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _loading.value = true;
    await _store.ensureCacheRoot();
    final plugins = await _store.getPlugins();
    _plugins.value = plugins;
    _loading.value = false;
  }

  Future<void> _import() async {
    if (_importing.value) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() => _importing.value = true);
    try {
      final bytes = await File(path).readAsBytes();
      final candidates = _importer.inspectZip(bytes);
      if (!mounted) return;
      if (candidates.isEmpty) {
        AppToast.show(context, '未识别到有效插件', type: ToastType.error);
        return;
      }

      // 展示候选列表让用户确认安装
      final confirmed = await showModalBottomSheet<List<String>>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => _ImportConfirmSheet(
          candidates: candidates,
          bytes: bytes,
        ),
      );
      if (confirmed == null || !mounted) return;

      // 逐个安装
      for (final id in confirmed) {
        final candidate = candidates.firstWhere((c) => c.manifest.id == id);
        final destDir = await _store.pluginDir(id);
        await _importer.extractPlugin(bytes, candidate.rootInArchive, destDir);
        final manifest = await _store.readManifest(destDir);
        if (manifest != null) {
          await _store.upsertPlugin(
            InstalledPlugin(manifest: manifest, dirPath: destDir),
          );
        }
      }
      if (mounted) AppToast.show(context, '已安装 ${confirmed.length} 个插件');
      await _load();
    } catch (e) {
      debugPrint('[DataSource] import error: $e');
      if (mounted) {
        AppToast.show(context, '导入失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _importing.value = false);
    }
  }

  Future<void> _togglePlugin(InstalledPlugin plugin, bool enabled) async {
    final updated = InstalledPlugin(
      manifest: plugin.manifest,
      dirPath: plugin.dirPath,
      enabled: enabled,
      metadataEnabled: plugin.metadataEnabled,
      lyricsEnabled: plugin.lyricsEnabled,
      coverEnabled: plugin.coverEnabled,
      config: plugin.config,
    );
    await _store.upsertPlugin(updated);
    await _load();
  }

  Future<void> _configurePlugin(InstalledPlugin plugin) async {
    if (plugin.manifest.configFields.isEmpty) {
      AppToast.show(context, '该插件没有可配置项');
      return;
    }
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PluginConfigSheet(plugin: plugin),
    );
    if (result == null || !mounted) return;
    final updated = InstalledPlugin(
      manifest: plugin.manifest,
      dirPath: plugin.dirPath,
      enabled: plugin.enabled,
      metadataEnabled: plugin.metadataEnabled,
      lyricsEnabled: plugin.lyricsEnabled,
      coverEnabled: plugin.coverEnabled,
      config: result,
    );
    await _store.upsertPlugin(updated);
    await _load();
  }

  Future<void> _uninstallPlugin(InstalledPlugin plugin) async {
    final ok = await AppDialog.showConfirm(
      context,
      title: '卸载插件',
      content: '确定卸载「${plugin.manifest.name}」？插件文件与配置将被移除。',
      confirmText: '卸载',
    );
    if (ok != true || !mounted) return;
    await _store.removePlugin(plugin.manifest.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '数据源维护',
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              IconButton(
                tooltip: '导入插件',
                onPressed: _importing.value ? null : _import,
                icon: _importing.value
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_box_outlined),
              ),
            ],
          ),
          showMiniPlayer: false,
          body: _buildBody(context),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading.value) {
      return const Center(child: CircularProgressIndicator());
    }
    final plugins = _plugins.value;
    if (plugins.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.extension_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有数据源插件',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '点击右上角导入 Lyrico 插件 zip',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: plugins.length,
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) => _reorder(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final plugin = plugins[index];
        // ReorderableListView 要求每个 item 有唯一 key（用于拖动重排）。
        return Padding(
          key: ValueKey(plugin.manifest.id),
          padding: const EdgeInsets.only(bottom: 10),
          child: _PluginCard(
            plugin: plugin,
            onToggle: (v) => _togglePlugin(plugin, v),
            onConfigure: () => _configurePlugin(plugin),
            onUninstall: () => _uninstallPlugin(plugin),
            dragEnabled: plugins.length > 1,
          ),
        );
      },
    );
  }

  /// 拖动排序：调整列表顺序后持久化 sortOrder。
  ///
  /// `onReorderItem` 的 newIndex 已是移除后的正确插入位置（新 API），
  /// 无需再 `newIndex -= 1`。
  void _reorder(int oldIndex, int newIndex) {
    if (_plugins.value.isEmpty) return;
    setState(() {
      final list = _plugins.value.toList();
      final moved = list.removeAt(oldIndex);
      list.insert(newIndex, moved);
      _plugins.value = list;
    });
    // 持久化新顺序（后台执行）
    _store.reorderPlugins(_plugins.value);
  }
}

/// 插件卡片。
class _PluginCard extends StatelessWidget {
  final InstalledPlugin plugin;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConfigure;
  final VoidCallback onUninstall;

  /// 是否显示拖动手柄（多插件时显示，长按/拖动排序）。
  final bool dragEnabled;

  const _PluginCard({
    required this.plugin,
    required this.onToggle,
    required this.onConfigure,
    required this.onUninstall,
    this.dragEnabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caps = plugin.manifest.capabilities
        .map(_capLabel)
        .join(' · ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (dragEnabled) ...[
                ReorderableDragStartListener(
                  index: 0,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              _pluginIcon(theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plugin.manifest.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'v${plugin.manifest.versionName} · ${plugin.manifest.id}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: plugin.enabled,
                onChanged: onToggle,
              ),
            ],
          ),
          if (caps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              caps,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          if (plugin.manifest.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              plugin.manifest.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: plugin.manifest.configFields.isEmpty ? null : onConfigure,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('配置'),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: onUninstall,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('卸载'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pluginIcon(ThemeData theme) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.extension_rounded,
        color: theme.colorScheme.primary,
      ),
    );
  }

  String _capLabel(PluginCapability cap) {
    switch (cap) {
      case PluginCapability.searchSongs:
        return '搜索歌曲';
      case PluginCapability.getLyrics:
        return '获取歌词';
      case PluginCapability.searchCovers:
        return '搜索封面';
    }
  }
}

/// 导入确认弹层：列出识别到的插件，勾选要安装的。
class _ImportConfirmSheet extends StatefulWidget {
  final List<PluginImportCandidate> candidates;
  final List<int> bytes;

  const _ImportConfirmSheet({required this.candidates, required this.bytes});

  @override
  State<_ImportConfirmSheet> createState() => _ImportConfirmSheetState();
}

class _ImportConfirmSheetState extends State<_ImportConfirmSheet> {
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.candidates.map((c) => c.manifest.id));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '选择要安装的插件',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final selected = _selected.contains(candidate.manifest.id);
                    return CheckboxListTile(
                      value: selected,
                      title: Text(candidate.manifest.name),
                      subtitle: Text(
                        'v${candidate.manifest.versionName} · ${candidate.manifest.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.add(candidate.manifest.id);
                          } else {
                            _selected.remove(candidate.manifest.id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(_selected.toList()),
                    child: Text('安装 (${_selected.length})'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 插件配置弹层：按 configFields 声明生成表单。
class _PluginConfigSheet extends StatefulWidget {
  final InstalledPlugin plugin;

  const _PluginConfigSheet({required this.plugin});

  @override
  State<_PluginConfigSheet> createState() => _PluginConfigSheetState();
}

class _PluginConfigSheetState extends State<_PluginConfigSheet> {
  late final Map<String, String> _values;

  @override
  void initState() {
    super.initState();
    _values = Map.of(widget.plugin.config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fields = widget.plugin.manifest.configFields;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '配置 ${widget.plugin.manifest.name}',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final field in fields) _buildField(theme, field),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_values),
                    child: const Text('保存配置'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildField(ThemeData theme, PluginConfigField field) {
    final value = _values[field.key] ?? field.defaultValue;
    switch (field.type) {
      case PluginConfigFieldType.dropdown:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: DropdownButtonFormField<String>(
            initialValue: field.options.any((o) => o.value == value)
                ? value
                : (field.options.isNotEmpty ? field.options.first.value : ''),
            decoration: InputDecoration(
              labelText: field.title,
              helperText: field.summary,
            ),
            items: field.options
                .map((o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _values[field.key] = v);
            },
          ),
        );
      case PluginConfigFieldType.switchField:
        final boolValue = value == 'true';
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SwitchListTile(
            title: Text(field.title),
            subtitle: field.summary != null ? Text(field.summary!) : null,
            value: boolValue,
            onChanged: (v) {
              setState(() => _values[field.key] = '$v');
            },
          ),
        );
      case PluginConfigFieldType.password:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
            initialValue: value,
            obscureText: true,
            decoration: InputDecoration(
              labelText: field.title,
              helperText: field.summary,
            ),
            onChanged: (v) => _values[field.key] = v,
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
            initialValue: value,
            keyboardType: field.type == PluginConfigFieldType.number
                ? TextInputType.number
                : null,
            maxLines: field.type == PluginConfigFieldType.textarea ? 4 : 1,
            decoration: InputDecoration(
              labelText: field.title,
              helperText: field.summary,
            ),
            onChanged: (v) => _values[field.key] = v,
          ),
        );
    }
  }
}
