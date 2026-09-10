import 'package:flutter/material.dart';

import '../../app/services/qq/qq_api_client.dart';
import '../../app/services/unblock/kugou_public_sources.dart';
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
  bool _probing = false;
  String? _probeReport;
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

  /// 探测用的曲目。故意挑时长差别大的几首 —— 时长是这里唯一拿得到的
  /// 身份证据，几首都对得上才说明它是按 id 映射，而不是按歌名瞎猜。
  static const List<String> _probeKeywords = [
    '少年 梦然',
    '晴天 周杰伦',
    '起风了 买辣椒也用券',
    '孤勇者 陈奕迅',
    '突然的自我 伍佰',
  ];

  /// 临时诊断：这两家公益源认不认 QQ（洛雪源代号 `tx`），以及**给的是不是
  /// 同一首歌**。
  ///
  /// 第一版只探一首，结果 haitangw 用 QQ 的 songmid 回了个**酷我**的 flac
  /// —— 说明它做的是跨平台匹配，不是按 QQ 的 id 取 QQ 的资源。那就有串到
  /// 同名翻唱的风险，光看「拿到地址了」根本不算数。
  ///
  /// 所以改成多首一起跑，每首比对 QQ 报的时长和文件大小反推的时长：
  /// 按 id 映射的话首首都该吻合，按歌名猜的话会散。
  ///
  /// 扣扣音乐眼下不在源列表里（取址接口会给打不开的 purl 且不带状态码，
  /// 见 music_source_registry 的注释），平时触发不到这条链，只能靠这个按钮
  /// 把结论问出来。有定论后这段就该删掉。
  Future<void> _probeQQPublicSources() async {
    setState(() {
      _probing = true;
      _probeReport = null;
    });
    final buf = StringBuffer();
    try {
      KugouPublicSources.resetProbes();
      for (final keyword in _probeKeywords) {
        final songs = await QQApiClient.instance.searchSongs(keyword, limit: 5);
        if (songs.isEmpty) {
          buf.writeln('$keyword → QQ 搜不到');
          buf.writeln('');
          continue;
        }
        final target = songs.firstWhere(
          (s) => s.payPlay,
          orElse: () => songs.first,
        );
        final qqSec = target.durationMs ~/ 1000;
        buf.writeln('${target.name} - ${target.artists}');
        buf.writeln('  mid ${target.mid} · QQ ${_mmss(qqSec)}'
            '${target.payPlay ? ' · 会员曲' : ''}');
        final results = await KugouPublicSources.probeAll(target.mid, 'tx');
        for (final entry in results.entries) {
          final url = entry.value;
          if (url == null) {
            buf.writeln('  ${entry.key}：没给地址');
            continue;
          }
          final host = Uri.tryParse(url)?.host ?? '?';
          final bytes = await KugouPublicSources.contentLength(url);
          buf.writeln('  ${entry.key}：$host ${_sizeDesc(bytes)}'
              ' → ${_bitrateVerdict(bytes, qqSec)}');
        }
        buf.writeln('');
      }
      if (KugouPublicSources.probes.isNotEmpty) {
        buf.writeln('原始返回：');
        for (final e in KugouPublicSources.probes.entries) {
          buf.writeln('${e.key} → ${e.value}');
        }
      }
    } catch (e) {
      buf.writeln('探测出错：$e');
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeReport = buf.toString().trim();
    });
  }

  static String _mmss(int seconds) {
    if (seconds <= 0) return '未知';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  static String _sizeDesc(int? bytes) {
    if (bytes == null || bytes <= 0) return '大小未知';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  /// 报**隐含码率**，不再报「估算时长」。
  ///
  /// 上一版按 900kbps 反推时长再和 QQ 比，结果 5 首里 4 首判「对不上」——
  /// 是尺子错了：那几首是 24bit Hi-Res flac（1650~1880kbps），按 900 算
  /// 自然差出一倍。真正的判据是这个比值本身：用文件大小除以 **QQ 报的
  /// 时长**，几首都落在同一个合理的 flac 区间，就说明拿到的确实是那首歌
  /// （配错歌的话这个比值会散得到处都是）。
  static String _bitrateVerdict(int? bytes, int qqSec) {
    if (bytes == null || bytes <= 0 || qqSec <= 0) return '无法比对';
    final kbps = (bytes * 8 / qqSec / 1000).round();
    final String tag;
    if (kbps >= 1300) {
      tag = 'Hi-Res flac';
    } else if (kbps >= 700) {
      tag = '标准 flac';
    } else if (kbps >= 250) {
      tag = '320k 级';
    } else if (kbps >= 90) {
      tag = '128k 级';
    } else {
      tag = '偏小，可疑';
    }
    return '$kbps kbps（$tag）';
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
          const SizedBox(height: 16),
          AppSettingSection(
            title: '诊断',
            children: [
              AppSettingTile(
                title: '探测公益音源',
                subtitle: _probing
                    ? '正在探测…（5 首 × 3 家，约半分钟）'
                    : '拿 5 首 QQ 歌问 haitangw / zddyr / lxmusic，看各家给什么',
                trailing: _probing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
                onTap: _probing ? null : _probeQQPublicSources,
              ),
            ],
          ),
          if (_probeReport != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              // 可选中：这段是要发给我看的，不能只让用户干瞪眼。
              child: SelectableText(
                _probeReport!,
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
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
