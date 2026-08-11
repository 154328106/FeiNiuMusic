import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router/app_router.dart';
import '../../app/services/lyrics/lyric_companion_service.dart';
import '../../app/state/settings_lyric_auto_search.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../components/index.dart';

/// 元数据匹配设置入口页。
///
/// 集中管理数据匹配相关功能：
/// - 数据源维护（Lyrico 插件导入/启用/配置）；
/// - 匹配设置（歌词偏好 / 元数据处理 / 并发）；
/// - 服务端增强（FnMusicEnhance 开关，支持歌词修改 + 歌手/专辑编辑）。
class MetadataMatchSettingsPage extends StatefulWidget {
  const MetadataMatchSettingsPage({super.key});

  @override
  State<MetadataMatchSettingsPage> createState() =>
      _MetadataMatchSettingsPageState();
}

class _MetadataMatchSettingsPageState extends State<MetadataMatchSettingsPage> {
  /// FnMusicEnhance 服务端增强仓库链接。
  static const String _companionRepoUrl =
      'https://github.com/kuilei0926/FnMusicEnhance';

  /// 探测中。
  bool _probing = true;

  /// 端口探测结果：null = 成功（服务端增强在 NAS 上运行）；否则为错误消息。
  String? _probeError;

  /// 服务端增强是否已连接（探测成功后置 true，供区块显示连接状态）。
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    LyricCompanionSettings.ensureLoaded();
    LyricAutoSearchSettings.ensureLoaded();
    // 加载「历史上曾检测到服务端增强」标记，用于区分未安装/已安装不可达。
    LyricCompanionService.ensureEverConnectedLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _probeCompanion();
  }

  /// 进入页面时探测 NAS 上 38200 端口（不校验 token，仅探测应用是否运行）。
  Future<void> _probeCompanion() async {
    setState(() {
      _probing = true;
      _probeError = null;
    });
    // 不带 token 探测 /health：服务可达即成功（auth=invalid 不影响可达性）。
    final error = await LyricCompanionService.instance.probe();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeError = error;
      _connected = error == null;
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
              const Divider(height: 1),
              ValueListenableBuilder<bool>(
                valueListenable: LyricAutoSearchSettings.enabled,
                builder: (context, enabled, _) {
                  return Column(
                    children: [
                      AppSettingSwitchTile(
                        title: '播放无歌词音乐时自动搜索',
                        subtitle: enabled
                            ? '播放时自动通过数据源插件搜索并应用歌词'
                            : '播放时遇到无歌词歌曲自动搜索歌词',
                        value: enabled,
                        onChanged: (value) =>
                            LyricAutoSearchSettings.setEnabled(value),
                      ),
                      if (enabled) ...[
                        const Divider(height: 1),
                        ValueListenableBuilder<bool>(
                          valueListenable: LyricAutoSearchSettings.writeBack,
                          builder: (context, writeBack, _) {
                            return AppSettingSwitchTile(
                              title: '搜索到后自动回写到 NAS',
                              subtitle: writeBack
                                  ? '命中歌词同步写入服务端增强，其他设备可用'
                                  : '仅本地使用，不回写到 NAS',
                              value: writeBack,
                              onChanged: (value) =>
                                  LyricAutoSearchSettings.setWriteBack(value),
                            );
                          },
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '服务端增强',
            children: _buildCompanionSection(context),
          ),
        ],
      ),
    );
  }

  /// 服务端增强（FnMusicEnhance）区块。
  ///
  /// 除歌词修改外，还提供歌手/专辑编辑（改名 + 封面写入）。
  /// 进入页面时探测 NAS 上 38200 端口，不可达则禁用开关并提供仓库链接。
  List<Widget> _buildCompanionSection(BuildContext context) {
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

    // 服务不可达：按「是否历史上检测到过一次」区分未安装 / 已安装不可达。
    if (_probeError != null) {
      // 曾检测到过 → 已安装，当前不可达：不提示安装，引导检查端口/网络。
      if (LyricCompanionService.instance.everConnected) {
        return [
          AppSettingTile(
            title: '服务端增强',
            subtitle: '已安装但当前不可达：请确认 NAS 上 FnMusicEnhance 正在运行，'
                '且端口 ${LyricCompanionService.port} 已开放',
            trailing: const Icon(Icons.warning_amber_rounded),
          ),
          AppSettingTile(
            title: '重新检测',
            subtitle: '再次探测服务端增强连接',
            leading: const Icon(Icons.refresh_rounded),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _probeCompanion,
          ),
        ];
      }
      // 从未检测到 → 未安装：禁用开关 + 提供 GitHub 链接。
      return [
        AppSettingTile(
          title: '服务端增强',
          subtitle: '未检测到已安装的 FnMusicEnhance',
          trailing: const Icon(Icons.warning_amber_rounded),
        ),
        AppSettingTile(
          title: '安装 / 配置 FnMusicEnhance',
          subtitle: '前往 GitHub 仓库查看安装说明',
          leading: const Icon(Icons.link_rounded),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: _openCompanionRepo,
        ),
      ];
    }

    return [
      AppSettingTile(
        title: '连接状态',
        subtitle: _connected
            ? '已连接到 NAS 上的 FnMusicEnhance'
            : '未连接：请确认 NAS 已运行 FnMusicEnhance，且端口 '
                '${LyricCompanionService.port} 已开放',
        leading: Icon(
          _connected ? Icons.check_circle_rounded : Icons.link_off_rounded,
          color: _connected ? Colors.green : null,
        ),
        trailing: TextButton(
          onPressed: _probing ? null : _probeCompanion,
          child: const Text('重新检测'),
        ),
      ),
      const Divider(height: 1),
      ValueListenableBuilder<bool>(
        valueListenable: LyricCompanionSettings.enabled,
        builder: (context, enabled, _) {
          return AppSettingSwitchTile(
            title: '服务端增强',
            subtitle: enabled
                ? '已开启：可修改歌词、编辑歌手/专辑'
                : '开启后支持歌词修改与歌手/专辑编辑',
            value: enabled,
            onChanged: (value) => _setCompanionEnabled(value),
          );
        },
      ),
    ];
  }

  Future<void> _setCompanionEnabled(bool value) async {
    if (value) {
      // 开启前探测 NAS 上 38200 端口 + 校验登录 token
      final error = await LyricCompanionService.instance.probe(
        checkKey: true,
      );
      if (!mounted) return;
      if (error != null) {
        AppToast.show(context, error, type: ToastType.error);
        return;
      }
      setState(() => _connected = true);
    }
    await LyricCompanionSettings.setEnabled(value);
  }
}
