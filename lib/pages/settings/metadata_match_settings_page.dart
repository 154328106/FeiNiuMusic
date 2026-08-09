import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/lyrics/lyric_companion_service.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../components/index.dart';

/// 元数据匹配设置入口页。
///
/// 集中管理数据匹配相关功能：
/// - 数据源维护（Lyrico 插件导入/启用/配置）；
/// - 匹配设置（歌词偏好 / 元数据处理 / 并发）；
/// - 配套编辑服务（FnMusicLyricsEditor 开关 / 密钥，支持歌词修改 + 歌手/专辑编辑）。
class MetadataMatchSettingsPage extends StatefulWidget {
  const MetadataMatchSettingsPage({super.key});

  @override
  State<MetadataMatchSettingsPage> createState() =>
      _MetadataMatchSettingsPageState();
}

class _MetadataMatchSettingsPageState extends State<MetadataMatchSettingsPage> {
  /// FnMusicLyricsEditor 配套应用仓库链接。
  static const String _companionRepoUrl =
      'https://github.com/kuilei0926/FnMusicLyricsEditor';

  /// 探测中。
  bool _probing = true;

  /// 端口探测结果：null = 成功（配套应用在 NAS 上运行）；否则为错误消息。
  String? _probeError;

  @override
  void initState() {
    super.initState();
    LyricCompanionSettings.ensureLoaded();
    _probeCompanion();
  }

  /// 进入页面时探测 NAS 上 38200 端口（不校验密钥，仅探测应用是否运行）。
  Future<void> _probeCompanion() async {
    setState(() {
      _probing = true;
      _probeError = null;
    });
    // 空密钥探测 /health：服务可达即成功（auth=invalid 不影响可达性）。
    final error = await LyricCompanionService.instance.probe('');
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeError = error;
    });
  }

  Future<void> _openCompanionRepo() async {
    final uri = Uri.parse(_companionRepoUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '元数据匹配',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppSettingSection(
            title: '数据源',
            children: [
              AppSettingTile(
                title: '数据源维护',
                subtitle: 'Lyrico 数据源插件管理',
                leading: const Icon(Icons.extension_outlined),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.dataSourceSettings,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '匹配偏好',
            children: [
              AppSettingTile(
                title: '匹配设置',
                subtitle: '歌词偏好 / 元数据处理 / 并发',
                leading: const Icon(Icons.tune_rounded),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.matchSettings,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '配套编辑服务',
            children: _buildCompanionSection(context),
          ),
        ],
      ),
    );
  }

  /// 配套编辑服务（FnMusicLyricsEditor）区块。
  ///
  /// 除歌词修改外，还提供歌手/专辑编辑（改名 + 封面写入）。
  /// 仅非中继（relayMode == false）连接下显示；中继时隐藏。
  /// 进入页面时探测 NAS 上 38200 端口，不可达则禁用开关并提供仓库链接。
  List<Widget> _buildCompanionSection(BuildContext context) {
    final relayMode = FeiNiuApiClient.instance.relayMode;
    if (relayMode) {
      return [
        AppSettingTile(
          title: '配套编辑服务',
          subtitle: '中继连接下不可用',
        ),
      ];
    }

    // 探测中
    if (_probing) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }

    // 端口不可达：禁用开关 + 提供 GitHub 链接
    if (_probeError != null) {
      return [
        AppSettingTile(
          title: '配套编辑服务',
          subtitle: '未检测到 NAS 上运行的 FnMusicLyricsEditor',
          trailing: const Icon(Icons.warning_amber_rounded),
        ),
        AppSettingTile(
          title: '安装 / 配置 FnMusicLyricsEditor',
          subtitle: '前往 GitHub 仓库查看安装说明',
          leading: const Icon(Icons.link_rounded),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: _openCompanionRepo,
        ),
      ];
    }

    return [
      ValueListenableBuilder<bool>(
        valueListenable: LyricCompanionSettings.enabled,
        builder: (context, enabled, _) {
          return Column(
            children: [
              AppSettingSwitchTile(
                title: '配套编辑服务',
                subtitle: enabled
                    ? '已开启：可修改歌词、编辑歌手/专辑'
                    : '开启后支持歌词修改与歌手/专辑编辑',
                value: enabled,
                onChanged: (value) => _setCompanionEnabled(value),
              ),
              // 服务密钥：仅在开启时显示；关闭后隐藏（对齐转码/高斯模糊/定时
              // 音量设置页的联动隐藏逻辑）。
              if (enabled)
                ValueListenableBuilder<String>(
                  valueListenable: LyricCompanionSettings.apiKey,
                  builder: (context, apiKey, _) {
                    return AppSettingTile(
                      title: '服务密钥',
                      subtitle: apiKey.isEmpty
                          ? '未设置（X-API-Key）'
                          : '已设置',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _inputApiKey,
                    );
                  },
                ),
            ],
          );
        },
      ),
    ];
  }

  Future<void> _setCompanionEnabled(bool value) async {
    if (value) {
      // 开启前探测 NAS 上 38200 端口 + 校验密钥
      if (LyricCompanionSettings.apiKey.value.isEmpty) {
        await _inputApiKey();
        if (!mounted) return;
        if (LyricCompanionSettings.apiKey.value.isEmpty) {
          AppToast.show(context, '请先设置密钥', type: ToastType.error);
          return;
        }
      }
      final error = await LyricCompanionService.instance
          .probe(LyricCompanionSettings.apiKey.value, checkKey: true);
      if (!mounted) return;
      if (error != null) {
        AppToast.show(context, error, type: ToastType.error);
        return;
      }
    }
    await LyricCompanionSettings.setEnabled(value);
  }

  Future<void> _inputApiKey() async {
    final controller = TextEditingController();
    final hasExisting = LyricCompanionSettings.apiKey.value.isNotEmpty;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('配套编辑服务密钥'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            // 不显示原密钥（含掩码），避免暴露；留空保留原密钥。
            hintText: '输入 X-API-Key',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          if (hasExisting)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_clearSentinel),
              child: const Text('清除'),
            ),
          FilledButton(
            // 必须用对话框自身的 context pop（外部 State.context 在嵌套
            // Navigator 下可能与对话框不在同一 Navigator，pop 无效导致
            // 点确定没反应）。
            onPressed: () {
              // 留空：保留原密钥，直接关闭（无改动）
              final value = controller.text.trim();
              Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    if (result == _clearSentinel) {
      await LyricCompanionSettings.setApiKey('');
      // 清空密钥后自动关闭歌词修改（无密钥无法写入歌词）。
      if (LyricCompanionSettings.enabled.value) {
        await LyricCompanionSettings.setEnabled(false);
      }
      if (!mounted) return;
      AppToast.show(context, '已清除密钥并关闭配套编辑服务');
      return;
    }
    await LyricCompanionSettings.setApiKey(result);
    if (!mounted) return;
    AppToast.show(context, '已保存密钥');
  }

  /// 清除密钥的哨兵值（与「留空保留」区分：空文本 = 保留，哨兵 = 清除）。
  static const String _clearSentinel = '__CLEAR__';
}
