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
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '配置',
            children: [
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _qualityController,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '音质',
                    hintText: '320k',
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
                    helperText: '占位符：{source} 平台代号、{id} 歌曲 id、{quality} 音质',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
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
            '密钥只保存在本机，不会上传。多个密钥会依次尝试，并记住最近可用的那个。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
