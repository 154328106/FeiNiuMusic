import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/services/backup/backup_service.dart';
import '../../app/services/webdav/webdav_source_repository.dart';
import '../../components/index.dart';

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  final BackupService _backup = BackupService.instance;

  BackupSections _sections = const BackupSections();
  AutoBackupConfig _auto = const AutoBackupConfig(
    enabled: false,
    sourceId: '',
    intervalHours: 24,
  );
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _backup.loadSections();
    final a = await _backup.loadAutoConfig();
    if (!mounted) return;
    setState(() {
      _sections = s;
      _auto = a;
      _loading = false;
    });
  }

  Future<void> _update(BackupSections s) async {
    setState(() => _sections = s);
    await _backup.saveSections(s);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- actions ----
  Future<void> _exportLocal() => _run(() async {
    if (!_sections.any) {
      AppToast.show(context, '请至少选择一项备份内容');
      return;
    }
    final path = await _backup.exportToFile(_sections);
    if (!mounted) return;
    await _showResultDialog('备份已导出', path, copyLabel: '复制路径');
  });

  Future<void> _importLocal() => _run(() async {
    final jsonStr = await _backup.pickBackupFile();
    if (jsonStr == null) {
      return;
    }
    if (!mounted) return;
    final confirmed = await _confirmImport();
    if (confirmed != true) return;
    try {
      final summary = await _backup.restoreFromJson(jsonStr);
      if (!mounted) return;
      _afterImport(summary);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导入失败：$e', type: ToastType.error);
    }
  });

  Future<void> _exportWebDav() => _run(() async {
    if (!_sections.any) {
      AppToast.show(context, '请至少选择一项备份内容');
      return;
    }
    final source = await _pickWebDavSource();
    if (source == null) return;
    try {
      await _backup.uploadToWebDav(source, _sections);
      if (!mounted) return;
      AppToast.show(
        context,
        '已上传到 ${source.name}/${BackupService.webDavFolder}',
        type: ToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '上传失败：$e', type: ToastType.error);
    }
  });

  Future<void> _importWebDav() => _run(() async {
    final source = await _pickWebDavSource();
    if (source == null) return;
    List<WebDavBackupEntry> entries;
    try {
      entries = await _backup.listWebDavBackups(source);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '读取备份列表失败：$e', type: ToastType.error);
      return;
    }
    if (!mounted) return;
    if (entries.isEmpty) {
      AppToast.show(context, '该 WebDAV 源没有找到备份');
      return;
    }
    final chosen = await _pickBackupEntry(entries);
    if (chosen == null) return;
    String jsonStr;
    try {
      jsonStr = await _backup.downloadFromWebDavPath(source, chosen.path);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '下载失败：$e', type: ToastType.error);
      return;
    }
    if (!mounted) return;
    final confirmed = await _confirmImport();
    if (confirmed != true) return;
    try {
      final summary = await _backup.restoreFromJson(jsonStr);
      if (!mounted) return;
      _afterImport(summary);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导入失败：$e', type: ToastType.error);
    }
  });

  Future<void> _toggleAuto(bool v) async {
    if (v) {
      final source = await _pickWebDavSource();
      if (source == null) return;
      await _backup.setAutoSourceId(source.id);
      await _backup.setAutoEnabled(true);
    } else {
      await _backup.setAutoEnabled(false);
    }
    final a = await _backup.loadAutoConfig();
    if (!mounted) return;
    setState(() => _auto = a);
  }

  Future<void> _changeAutoSource() async {
    final source = await _pickWebDavSource();
    if (source == null) return;
    await _backup.setAutoSourceId(source.id);
    final a = await _backup.loadAutoConfig();
    if (!mounted) return;
    setState(() => _auto = a);
    AppToast.show(context, '自动备份目标已设为 ${source.name}');
  }

  Future<void> _changeAutoInterval() async {
    const options = [6, 12, 24, 48, 168];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '最短备份间隔',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (final h in options)
              ListTile(
                title: Text(_intervalLabel(h)),
                trailing: _auto.intervalHours == h
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, h),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _backup.setAutoIntervalHours(picked);
    final a = await _backup.loadAutoConfig();
    if (!mounted) return;
    setState(() => _auto = a);
  }

  String _intervalLabel(int h) {
    if (h % 24 == 0) return '每 ${h ~/ 24} 天';
    return '每 $h 小时';
  }

  Future<WebDavBackupEntry?> _pickBackupEntry(
    List<WebDavBackupEntry> entries,
  ) {
    String fmtTime(DateTime? t) {
      if (t == null) return '未知时间';
      String two(int v) => v.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    }

    String fmtSize(int b) {
      if (b <= 0) return '';
      if (b < 1024) return ' · $b B';
      if (b < 1024 * 1024) return ' · ${(b / 1024).toStringAsFixed(0)} KB';
      return ' · ${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return showModalBottomSheet<WebDavBackupEntry>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '选择要恢复的备份',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return ListTile(
                        leading: Icon(
                          e.isCurrentDevice
                              ? Icons.smartphone_rounded
                              : Icons.devices_other_rounded,
                        ),
                        title: Text(fmtTime(e.modified)),
                        subtitle: Text(
                          '${e.isCurrentDevice ? '本机' : '设备 ${e.deviceId ?? '?'}'}${fmtSize(e.sizeBytes)}',
                        ),
                        onTap: () => Navigator.pop(context, e),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _afterImport(String summary) {
    final needsRestart = _sections.settings || _sections.sources;
    AppToast.show(
      context,
      needsRestart ? '$summary（部分设置/音源需重启生效）' : summary,
      type: ToastType.success,
    );
  }

  Future<WebDavSource?> _pickWebDavSource() async {
    final sources = await _backup.webDavSources();
    if (!mounted) return null;
    if (sources.isEmpty) {
      AppToast.show(context, '请先在「音源」中添加一个 WebDAV 源');
      return null;
    }
    if (sources.length == 1) return sources.first;
    return showModalBottomSheet<WebDavSource>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择 WebDAV 源',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              for (final s in sources)
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(s.name),
                  subtitle: Text(
                    s.endpoint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, s),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<bool?> _confirmImport() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text(
          '将以「智能合并」方式导入：歌单按名称合并、听歌统计累加、音源/设置按需覆盖。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  Future<void> _showResultDialog(
    String title,
    String path, {
    required String copyLabel,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(path),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!mounted) return;
              Navigator.pop(context);
              AppToast.show(context, '已复制');
            },
            child: Text(copyLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(context);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '数据备份',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
              children: [
                AppSettingSection(
                  title: '备份内容',
                  children: [
                    AppSettingSwitchTile(
                      title: '歌单',
                      subtitle: '所有歌单与「我喜欢」',
                      value: _sections.playlists,
                      onChanged: (v) =>
                          _update(_sections.copyWith(playlists: v)),
                    ),
                    AppSettingSwitchTile(
                      title: '听歌统计',
                      subtitle: '播放时长与次数等统计数据',
                      value: _sections.stats,
                      onChanged: (v) => _update(_sections.copyWith(stats: v)),
                    ),
                    AppSettingSwitchTile(
                      title: '音源配置',
                      subtitle: 'WebDAV / Navidrome 账号（含密码，请妥善保管备份文件）',
                      value: _sections.sources,
                      onChanged: (v) => _update(_sections.copyWith(sources: v)),
                    ),
                    AppSettingSwitchTile(
                      title: '应用设置',
                      subtitle: '主题、播放器外观、流光等偏好（导入后需重启生效）',
                      value: _sections.settings,
                      onChanged: (v) =>
                          _update(_sections.copyWith(settings: v)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: '本地',
                  children: [
                    AppSettingTile(
                      title: '导出到本地文件',
                      subtitle: '生成 JSON 备份文件',
                      leading: const Icon(Icons.save_alt_rounded),
                      trailing: _busy
                          ? _spinner()
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _exportLocal,
                    ),
                    AppSettingTile(
                      title: '从本地文件导入',
                      subtitle: '选择一个备份 JSON 文件',
                      leading: const Icon(Icons.file_open_rounded),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _importLocal,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: 'WebDAV 云端',
                  children: [
                    AppSettingTile(
                      title: '上传到 WebDAV',
                      subtitle: '保存到 WebDAV 的 ${BackupService.webDavFolder} 目录',
                      leading: const Icon(Icons.cloud_upload_rounded),
                      trailing: _busy
                          ? _spinner()
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _exportWebDav,
                    ),
                    AppSettingTile(
                      title: '从 WebDAV 导入',
                      subtitle: '从云端备份历史中选择一个恢复',
                      leading: const Icon(Icons.cloud_download_rounded),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _busy ? null : _importWebDav,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: '自动备份',
                  children: [
                    AppSettingSwitchTile(
                      title: '启动时自动备份到 WebDAV',
                      subtitle: '打开应用时按下面的间隔自动上传一份备份',
                      value: _auto.enabled,
                      onChanged: _toggleAuto,
                    ),
                    if (_auto.enabled) ...[
                      AppSettingTile(
                        title: '备份间隔',
                        subtitle: '最短 ${_intervalLabel(_auto.intervalHours)} 自动备份一次',
                        leading: const Icon(Icons.timer_outlined),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _busy ? null : _changeAutoInterval,
                      ),
                      AppSettingTile(
                        title: '更换目标源',
                        subtitle: '选择用于自动备份的 WebDAV 源',
                        leading: const Icon(Icons.cloud_outlined),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _busy ? null : _changeAutoSource,
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  Widget _spinner() => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
