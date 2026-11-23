import 'package:flutter/material.dart';

import '../../app/router/app_page_route.dart';
import '../../app/services/lxscript/lx_source_manager.dart';
import '../../app/services/unblock/unblock_source.dart';
import '../../components/index.dart';
import 'lx_source_page.dart';

class UnblockSourcePage extends StatefulWidget {
  const UnblockSourcePage({super.key});

  @override
  State<UnblockSourcePage> createState() => _UnblockSourcePageState();
}

class _UnblockSourcePageState extends State<UnblockSourcePage> {
  final _service = UnblockSourceService.instance;
  final _keysController = TextEditingController();
  final _ikunController = TextEditingController();
  final _qualityController = TextEditingController();

  bool _enabled = true;
  bool _testing = false;

  bool _switchesOpen = false;
  bool _configOpen = false;

  bool _revealSecrets = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    await _service.load();
    await LxSourceManager.instance.ensureLoaded();
    if (!mounted) return;
    final cfg = _service.config.value;
    _keysController.text = cfg.apiKeys.join('\n');
    _ikunController.text = cfg.ikunKey;
    _qualityController.text = cfg.quality;
    setState(() => _enabled = cfg.enabled);
  }

  @override
  void dispose() {
    _keysController.dispose();
    _ikunController.dispose();
    _qualityController.dispose();
    super.dispose();
  }

  static const List<(String, String, String)> _qualityPresets = [
    ('128k', '流畅', '128 kbps，省流量'),
    ('320k', '标准', '320 kbps，默认'),
    ('flac', '无损', 'FLAC，取不到会自动退回 320k'),
    ('flac24bit', 'Hi-Res', '24bit 母带，货最少'),
  ];

  String _maskKey(String key) {
    if (key.length <= 4) return '•' * key.length;
    return '••••••${key.substring(key.length - 4)}';
  }

  String _keysSummary() {
    final keys = _keysController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (keys.isEmpty) return '未填写';
    return '${keys.length} 个 · ${keys.map(_maskKey).join('，')}';
  }

  String _ikunSummary() {
    final key = _ikunController.text.trim();
    return key.isEmpty ? '未填写' : _maskKey(key);
  }

  UnblockSourceConfig _currentConfig() => UnblockSourceConfig(
    apiKeys: _keysController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
    ikunKey: _ikunController.text.trim(),
    quality: _qualityController.text.trim().isEmpty
        ? '320k'
        : _qualityController.text.trim(),
    enabled: _enabled,
  );

  String _qualityLabel() {
    final current = _qualityController.text.trim();
    for (final (value, name, _) in _qualityPresets) {
      if (value == current) return '$name（$value）';
    }
    return current.isEmpty ? '标准（320k）' : '自定义（$current）';
  }

  Future<void> _pickQuality() async {
    final current = _qualityController.text.trim();
    final isPreset = _qualityPresets.any((e) => e.$1 == current);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择音质',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (final (value, name, desc) in _qualityPresets)
              ListTile(
                title: Text(name),
                subtitle: Text(desc),
                trailing: current == value
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
            ListTile(
              title: const Text('自定义'),
              subtitle: Text(
                isPreset || current.isEmpty ? '自己填写音质参数' : '当前：$current',
              ),
              trailing: !isPreset && current.isNotEmpty
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(context, '__custom__'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == '__custom__') {
      await _editCustomQuality();
      return;
    }
    setState(() => _qualityController.text = picked);
  }

  Future<void> _editCustomQuality() async {
    final controller = TextEditingController(text: _qualityController.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义音质'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: '例如 320k / flac / 999',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty || !mounted) return;
    setState(() => _qualityController.text = result);
  }

  Future<void> _save() async {
    await _service.save(_currentConfig());
    if (!mounted) return;
    AppToast.show(context, '已保存');
  }

  Future<void> _test() async {
    await _service.save(_currentConfig());
    setState(() {
      _testing = true;
      _result = null;
    });
    final url = await _service.resolve(platform: 'wy', songId: '347230');
    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultOk = url != null;
      _result = url != null
          ? '连接成功，已取到播放地址'
          : '未取到地址。可能是密钥无效或额度用尽；也可能只是这首歌上游没货，'
                '换首歌再试。详情见「查看日志」';
    });
  }

  Widget _collapsible({
    required String title,
    required IconData icon,
    required String collapsedSubtitle,
    required bool expanded,
    required VoidCallback onToggle,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingSection(
      children: [
        AppSettingTile(
          title: title,
          subtitle: expanded ? '收起' : collapsedSubtitle,
          leading: Icon(icon, size: 22, color: scheme.primary),
          trailing: AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.chevron_right_rounded),
          ),
          onTap: onToggle,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(children: children)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: '第三方音源'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          AppPageScaffold.scrollableBottomPadding(context),
        ),
        children: [
          _collapsible(
            title: '音源开关',
            icon: Icons.power_settings_new_rounded,
            collapsedSubtitle: _enabled ? '已开启三方音源' : '已关闭',
            expanded: _switchesOpen,
            onToggle: () => setState(() => _switchesOpen = !_switchesOpen),
            children: [
              AppSettingSwitchTile(
                title: '开启三方音源',
                subtitle: _enabled ? '官方无法播放时自动尝试音源' : '关闭后灰色/会员歌曲将直接跳过',
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              ListenableBuilder(
                listenable: Listenable.merge([
                  UnblockSourceService.instance.freeFallbackEnabled,
                  UnblockSourceService.instance.config,
                  LxSourceManager.instance.revision,
                ]),
                builder: (context, _) {
                  final svc = UnblockSourceService.instance;
                  final on = svc.freeFallbackEnabled.value;
                  return AppSettingSwitchTile(
                    title: '免费兜底音源',
                    subtitle: on
                        ? '上面的音源没配或没命中时，再试 GD Studio / 酷狗 / 酷我'
                        : svc.freeFallbackActive
                        ? '没配音源、也没启用脚本，为了能播仍会用免费音源'
                        : '关闭后只用上面配置的音源',
                    value: on,
                    onChanged: svc.setFreeFallbackEnabled,
                  );
                },
              ),
              ListenableBuilder(
                listenable: Listenable.merge([
                  UnblockSourceService.instance.preferLxEnabled,
                  LxSourceManager.instance.revision,
                ]),
                builder: (context, _) {
                  final on =
                      UnblockSourceService.instance.preferLxEnabled.value;
                  return AppSettingSwitchTile(
                    title: '开启脚本音源',
                    subtitle: on && !LxSourceManager.instance.hasEnabled
                        ? '还没导入或启用音源脚本，暂不生效'
                        : on
                        ? '脚本音源参与竞速取址，谁快用谁'
                        : '不启用脚本音源',
                    value: on,
                    onChanged: UnblockSourceService.instance.setPreferLxEnabled,
                  );
                },
              ),
              ListenableBuilder(
                listenable:
                    UnblockSourceService.instance.cellularDowngradeEnabled,
                builder: (context, _) {
                  final on = UnblockSourceService
                      .instance
                      .cellularDowngradeEnabled
                      .value;
                  return AppSettingSwitchTile(
                    title: '开启弱网优化',
                    subtitle: on
                        ? '用流量时固定按 128k 取址，省流量、弱网下也更容易出链'
                        : '始终按上面选择的音质取址，不因为在用流量而改变',
                    value: on,
                    onChanged: UnblockSourceService
                        .instance
                        .setCellularDowngradeEnabled,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _collapsible(
            title: '音质配置',
            icon: Icons.tune_rounded,
            collapsedSubtitle: '选择音质 ${_qualityLabel()} · 密钥',
            expanded: _configOpen,
            onToggle: () => setState(() => _configOpen = !_configOpen),
            children: [
              AppSettingTile(
                title: '选择音质',
                subtitle: _qualityLabel(),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickQuality,
              ),
              AppSettingSwitchTile(
                title: '显示密钥',
                subtitle: _revealSecrets ? '当前明文显示，注意别截图' : '默认遮住，避免截图或旁人看到',
                value: _revealSecrets,
                onChanged: (v) => setState(() => _revealSecrets = v),
              ),
              if (!_revealSecrets) ...[
                AppSettingTile(title: '密钥配置', subtitle: _keysSummary()),
                AppSettingTile(title: 'ikun 密钥', subtitle: _ikunSummary()),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _keysController,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '密钥配置',
                      hintText: '一行一个，可填多个',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: TextField(
                    controller: _ikunController,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'ikun 密钥',
                      hintText: '聚合音源-A（c.wwwweb.top）的密钥',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            children: [
              AppSettingTile(
                leading: Icon(
                  Icons.code_rounded,
                  size: 22,
                  color: scheme.primary,
                ),
                title: '脚本音源',
                subtitle: 'Js 脚本文件配置',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(
                  context,
                ).push(buildAppPageRoute((_) => const LxSourcePage())),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _testing ? null : _save,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _testing ? null : _test,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试'),
                ),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  _resultOk
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: _resultOk ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _result!,
                    style: TextStyle(
                      color: _resultOk ? scheme.primary : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
