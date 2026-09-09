import 'package:flutter/material.dart';

import '../../app/services/unblock/unblock_source.dart';
import '../../components/index.dart';

/// 第三方音源设置。
///
/// 官方给不出播放地址（灰色 / 无版权 / 需要会员）时，转向这里配置的音源要。
/// **不内置密钥**：没填就完全不生效，一个请求都不会发。
class UnblockSourcePage extends StatefulWidget {
  const UnblockSourcePage({super.key});

  @override
  State<UnblockSourcePage> createState() => _UnblockSourcePageState();
}

class _UnblockSourcePageState extends State<UnblockSourcePage> {
  final _service = UnblockSourceService.instance;
  final _templateController = TextEditingController();
  final _keysController = TextEditingController();
  final _qualityController = TextEditingController();

  bool _enabled = true;
  bool _testing = false;
  /// 密钥/接口地址默认遮住。它们平时没有再看一眼的必要，露着只是徒增
  /// 截图和旁人瞄一眼的风险。
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
    if (!mounted) return;
    final cfg = _service.config.value;
    _templateController.text = cfg.template;
    // 一行一个密钥：比逗号分隔好读，也不怕密钥里带逗号。
    _keysController.text = cfg.apiKeys.join('\n');
    _qualityController.text = cfg.quality;
    setState(() => _enabled = cfg.enabled);
  }

  @override
  void dispose() {
    _templateController.dispose();
    _keysController.dispose();
    _qualityController.dispose();
    super.dispose();
  }

  /// 音质预设。值必须是 [FreeUnblockSources.gdBitrate] 认得的写法，同时也会
  /// 原样替换进自配音源接口模板里的 {quality}。
  static const List<(String, String, String)> _qualityPresets = [
    ('128k', '流畅', '128 kbps，省流量'),
    ('320k', '标准', '320 kbps，默认'),
    ('flac', '无损', 'FLAC，取不到会自动退回 320k'),
    ('flac24bit', 'Hi-Res', '24bit 母带，货最少'),
  ];

  /// 密钥遮罩：只留末 4 位，够用来分辨是哪一个，又认不出全貌。
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

  /// 接口地址遮罩：露主机名的头两位和后缀，剩下打点。
  String _templateSummary() {
    final text = _templateController.text.trim();
    if (text.isEmpty) return '未填写';
    final host = Uri.tryParse(text)?.host ?? '';
    if (host.isEmpty) return '已配置';
    final dot = host.lastIndexOf('.');
    if (dot <= 2) return '已配置';
    return '已配置 · ${host.substring(0, 2)}••••${host.substring(dot)}';
  }

  UnblockSourceConfig _currentConfig() => UnblockSourceConfig(
    template: _templateController.text.trim(),
    apiKeys: _keysController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
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
                '音质',
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
            // 自配音源的接口模板里 {quality} 是原样替换的，别的源可能要别的
            // 写法。写死成列表会把那些源打死，留个口子。
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

  /// 用一首确定是 VIP 的歌试连通性。成功与否都把原因写出来。
  Future<void> _test() async {
    await _service.save(_currentConfig());
    setState(() {
      _testing = true;
      _result = null;
    });
    // 梦然《少年》，网易云 id 347230。
    // 不要用《晴天》(186016) 之类的热门 VIP 曲做探针：上游源对个别歌曲本来
    // 就没货，会返回 `code 500 / returned no URL`，看着像密钥无效，实际是
    // 这一首取不到 —— 我自己就被这个误导过一轮。
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: '第三方音源'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppSettingSection(
            title: '开关',
            children: [
              AppSettingSwitchTile(
                title: '启用第三方音源',
                subtitle: _enabled ? '官方无法播放时自动尝试音源' : '关闭后灰色/会员歌曲将直接跳过',
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    UnblockSourceService.instance.freeFallbackEnabled,
                builder: (context, on, _) => AppSettingSwitchTile(
                  title: '免费兜底音源',
                  subtitle: on
                      ? '上面的音源没配或没命中时，再试 GD Studio / 酷狗 / 酷我'
                      : '关闭后只用上面配置的音源',
                  value: on,
                  onChanged:
                      UnblockSourceService.instance.setFreeFallbackEnabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '配置',
            children: [
              AppSettingTile(
                title: '音质',
                subtitle: _qualityLabel(),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickQuality,
              ),
              AppSettingSwitchTile(
                title: '显示密钥与接口地址',
                subtitle: _revealSecrets
                    ? '当前明文显示，注意别截图'
                    : '默认遮住，避免截图或旁人看到',
                value: _revealSecrets,
                onChanged: (v) => setState(() => _revealSecrets = v),
              ),
              if (!_revealSecrets) ...[
                AppSettingTile(title: 'API 密钥', subtitle: _keysSummary()),
                AppSettingTile(
                  title: '接口地址',
                  subtitle: _templateSummary(),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _keysController,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'API 密钥',
                      hintText: '一行一个，可填多个',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: TextField(
                    controller: _templateController,
                    minLines: 2,
                    maxLines: 4,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '接口地址',
                      helperText:
                          '占位符：{source} 平台代号、{id} 歌曲 id、{quality} 音质',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _testing ? null : _save,
                  child: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存并测试'),
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
          const SizedBox(height: 20),
          Text(
            '密钥只保存在本机，不会上传，也不会写进日志。多个密钥会依次尝试，'
            '并记住最近可用的那个。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
