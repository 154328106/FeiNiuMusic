import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../app/state/settings_state.dart';
import '../../app/utils/image_crop_helper.dart';
import '../../components/index.dart';

class AppAppearanceSettingsPage extends StatefulWidget {
  const AppAppearanceSettingsPage({super.key});

  @override
  State<AppAppearanceSettingsPage> createState() =>
      _AppAppearanceSettingsPageState();
}

class _AppAppearanceSettingsPageState extends State<AppAppearanceSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppLayoutSettings.ensureLoaded();
    AppThemeSettings.ensureLoaded();
    AppBackgroundSettings.ensureLoaded();
    AppGlassSettings.ensureLoaded();
  }

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Widget _modeTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = selected
        ? scheme.primary
        : (isDark ? Colors.white12 : Colors.black12);
    final iconColor = selected
        ? scheme.primary
        : (isDark ? Colors.white70 : Colors.black54);
    final textColor = selected
        ? scheme.primary
        : (isDark ? Colors.white70 : Colors.black87);
    final background = selected
        ? scheme.primary.withAlpha(31)
        : Colors.transparent;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12, color: textColor)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeRow(
    BuildContext context, {
    required ThemeMode selected,
    required ValueChanged<ThemeMode> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          _modeTile(
            context,
            icon: Icons.phone_android,
            label: _themeLabel(ThemeMode.system),
            selected: selected == ThemeMode.system,
            onTap: () => onChanged(ThemeMode.system),
          ),
          const SizedBox(width: 8),
          _modeTile(
            context,
            icon: Icons.light_mode_outlined,
            label: _themeLabel(ThemeMode.light),
            selected: selected == ThemeMode.light,
            onTap: () => onChanged(ThemeMode.light),
          ),
          const SizedBox(width: 8),
          _modeTile(
            context,
            icon: Icons.dark_mode_outlined,
            label: _themeLabel(ThemeMode.dark),
            selected: selected == ThemeMode.dark,
            onTap: () => onChanged(ThemeMode.dark),
          ),
        ],
      ),
    );
  }

  Future<void> _showThemeColorPickerDialog(BuildContext context) async {
    final current =
        AppThemeSettings.themeSeedColor.value ?? const Color(0xFF3B82F6);
    await showDialog(
      context: context,
      builder: (context) {
        return _ThemeColorPickerDialog(
          initialColor: current,
          onSelected: (color) {
            AppThemeSettings.setDynamicColorEnabled(false);
            AppThemeSettings.setThemeSeedColor(color);
          },
        );
      },
    );
  }

  Widget _presetColorItem({
    required Widget child,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(child: child),
      ),
    );
  }

  Future<void> _showBackgroundImageSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('选择图片'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _pickAndCropBackground(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('清除背景'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await AppBackgroundSettings.setBackgroundImagePath(null);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Pick a source image, launch the uCrop editor with the aspect ratio of the
  /// current device screen, and save the cropped output as the new background.
  Future<void> _pickAndCropBackground(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final file = result?.files.first;
    if (file?.path == null) return;

    // Use the device's short/long dimensions so the crop frame matches what
    // the wallpaper will actually be painted into. Reading it once here is
    // fine — no need to react to rotation while the cropper UI is on screen.
    if (!context.mounted) return;
    final size = MediaQuery.of(context).size;

    final cropped = await cropCoverImage(
      sourcePath: file!.path!,
      ratioX: size.width,
      ratioY: size.height,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪背景',
          hideBottomControls: true,
          lockAspectRatio: true,
          // Explicit toolbar / status bar tint so the confirm/cancel icons
          // never blend into the phone's system bar (which was the "点几下才
          // 点得到" bug on notched screens).
          toolbarColor: const Color(0xFF212121),
          statusBarLight: false,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: Colors.white,
          backgroundColor: Colors.black,
        ),
        IOSUiSettings(
          title: '裁剪背景',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    if (cropped == null) return;

    // uCrop writes to a cache directory that OS may sweep; copy the output
    // into our app documents dir so the background survives across launches.
    final docs = await getApplicationDocumentsDirectory();
    final targetPath = path.join(
      docs.path,
      'background_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await File(cropped.path).copy(targetPath);
    await AppBackgroundSettings.setBackgroundImagePath(targetPath);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '应用外观',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          // 平板/TV/Windows 恒用侧边栏大屏布局，不提供底栏模式切换，隐藏整块。
          ValueListenableBuilder<bool>(
            valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
            builder: (context, effectiveTabletMode, _) {
              if (effectiveTabletMode) return const SizedBox.shrink();
              return AppSettingSection(
                title: '导航布局',
                children: [
                  ValueListenableBuilder<AppNavigationStyle>(
                    valueListenable: AppLayoutSettings.navigationStyle,
                    builder: (context, style, _) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '导航方式',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: SegmentedButton<AppNavigationStyle>(
                                segments: const [
                                  ButtonSegment(
                                    value: AppNavigationStyle.drawer,
                                    icon: Icon(Icons.menu_open_rounded),
                                    label: Text('侧边栏'),
                                  ),
                                  ButtonSegment(
                                    value: AppNavigationStyle.bottomBar,
                                    icon: Icon(Icons.space_dashboard_outlined),
                                    label: Text('底部导航'),
                                  ),
                                ],
                                selected: {style},
                                showSelectedIcon: false,
                                onSelectionChanged: (selection) {
                                  AppLayoutSettings.setNavigationStyle(
                                    selection.first,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              style == AppNavigationStyle.bottomBar
                                  ? '四个常用入口固定在底部，专辑、歌手与文件夹仍从音乐库进入'
                                  : '保留当前从左侧菜单访问各页面的方式',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          AppCollapsibleSettingSection(
            title: '外观设置',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppLayoutSettings.tabletMode,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '平板模式',
                    subtitle: '优化平板布局',
                    value: enabled,
                    onChanged: (value) {
                      AppLayoutSettings.setTabletMode(value);
                    },
                  );
                },
              ),
              // TV 模式：手动强制开启 TV 布局 + 遥控器焦点导航。
              // 开发/调试用：在手机或非 TV 设备上直接预览 TV 页面效果。
              ValueListenableBuilder<bool>(
                valueListenable: AppLayoutSettings.forceTvMode,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: 'TV 模式',
                    subtitle: '强制 TV 布局与遥控器操作',
                    value: enabled,
                    onChanged: (value) {
                      AppLayoutSettings.setForceTvMode(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppThemeSettings.dynamicColorEnabled,
                builder: (context, enabled, _) {
                  return ValueListenableBuilder<Color?>(
                    valueListenable: AppThemeSettings.themeSeedColor,
                    builder: (context, seedColor, _) {
                      // 白色顶掉了原来和蓝色太像的靛蓝。
                      final colors = [
                        const Color(0xFFFFFFFF),
                        const Color(0xFF3B82F6),
                        const Color(0xFF22C55E),
                        const Color(0xFFA855F7),
                        const Color(0xFFF97316),
                        const Color(0xFFEF4444),
                        const Color(0xFFEC4899),
                        const Color(0xFF14B8A6),
                      ];
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '主题色',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              enabled ? '已启用系统动态颜色' : '设置应用主色调',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 44,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  if (seedColor != null &&
                                      !colors.any(
                                        (c) =>
                                            c.toARGB32() ==
                                            seedColor.toARGB32(),
                                      )) ...[
                                    _presetColorItem(
                                      selected: true,
                                      onTap: () {},
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          color: seedColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  _presetColorItem(
                                    selected: false,
                                    onTap: () =>
                                        _showThemeColorPickerDialog(context),
                                    child: Icon(
                                      Icons.palette_outlined,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  for (final color in colors) ...[
                                    _presetColorItem(
                                      selected:
                                          seedColor?.toARGB32() ==
                                          color.toARGB32(),
                                      onTap: () =>
                                          AppThemeSettings.setDynamicColorEnabled(
                                            false,
                                          ).then(
                                            (_) =>
                                                AppThemeSettings.setThemeSeedColor(
                                                  color,
                                                ),
                                          ),
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          color: color,
                                          shape: BoxShape.circle,
                                          // 白色圆点在浅色背景上看不见，描一圈。
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outlineVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  _presetColorItem(
                                    selected: seedColor == null,
                                    onTap: () =>
                                        AppThemeSettings.setDynamicColorEnabled(
                                          false,
                                        ).then(
                                          (_) =>
                                              AppThemeSettings.setThemeSeedColor(
                                                null,
                                              ),
                                        ),
                                    child: Icon(
                                      Icons.refresh_rounded,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: AppThemeSettings.themeMode,
                builder: (context, mode, _) {
                  return _modeRow(
                    context,
                    selected: mode,
                    onChanged: (value) {
                      AppThemeSettings.setThemeMode(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppThemeSettings.dynamicColorEnabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '使用系统动态颜色',
                    subtitle: '仅 Android 12+ 生效',
                    value: enabled,
                    onChanged: (value) {
                      AppThemeSettings.setDynamicColorEnabled(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<String?>(
                valueListenable: AppBackgroundSettings.backgroundImagePath,
                builder: (context, pathValue, _) {
                  final name = pathValue == null || pathValue.isEmpty
                      ? '未设置'
                      : path.basename(pathValue);
                  final hasImage =
                      pathValue != null && pathValue.trim().isNotEmpty;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppSettingTile(
                        title: '自定义背景',
                        subtitle: name,
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _showBackgroundImageSheet(context),
                      ),
                      if (hasImage)
                        ValueListenableBuilder<double>(
                          valueListenable:
                              AppBackgroundSettings.backgroundMaskOpacity,
                          builder: (context, value, _) {
                            return AppSettingSlider(
                              title: '图片透明度',
                              value: (value * 100).clamp(0, 100),
                              min: 0,
                              max: 100,
                              divisions: 100,
                              valueText: '${(value * 100).round()}%',
                              onChanged: (next) {
                                AppBackgroundSettings.setBackgroundMaskOpacity(
                                  next / 100,
                                );
                              },
                            );
                          },
                        ),
                      if (hasImage)
                        ValueListenableBuilder<double>(
                          valueListenable:
                              AppBackgroundSettings.backgroundBlurSigma,
                          builder: (context, sigma, _) {
                            return AppSettingSlider(
                              title: '图片模糊',
                              description: '0 = 保持原图清晰',
                              value: sigma.clamp(0, 32),
                              min: 0,
                              max: 32,
                              divisions: 32,
                              valueText: sigma.toStringAsFixed(0),
                              onChanged: (next) {
                                AppBackgroundSettings.setBackgroundBlurSigma(
                                  next,
                                );
                              },
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    AppBackgroundSettings.miniPlayerOnlyWhilePlaying,
                builder: (context, only, _) {
                  return AppSettingSwitchTile(
                    title: '仅播放时显示播放条',
                    subtitle: only ? '暂停后播放条会收起，需从播放页或列表恢复播放' : '播放条常驻底部',
                    value: only,
                    onChanged:
                        AppBackgroundSettings.setMiniPlayerOnlyWhilePlaying,
                  );
                },
              ),
              // 导航栏的底色 / 深浅 / 描边已移到下方「底部栏」分区，和播放条
              // 共用一套样式（AppSurfaceSettings）。
              ValueListenableBuilder<bool>(
                valueListenable: AppBackgroundSettings.panelBlurEnabled,
                builder: (context, blurEnabled, _) {
                  return AppSettingSwitchTile(
                    title: '高斯模糊',
                    subtitle: blurEnabled
                        ? '面板、底部音乐条等使用毛玻璃效果（会关闭液体玻璃）'
                        : '关闭后所有高斯模糊渲染',
                    value: blurEnabled,
                    onChanged: (value) {
                      AppBackgroundSettings.setPanelBlurEnabled(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppBackgroundSettings.panelBlurEnabled,
                builder: (context, blurEnabled, _) {
                  // 关闭「高斯模糊」→ 隐藏下方「模糊强度」滑块（避免显示无效的
                  // 「已关闭」控件，对齐转码设置页的联动隐藏逻辑）。
                  if (!blurEnabled) return const SizedBox.shrink();
                  return ValueListenableBuilder<double>(
                    valueListenable: AppBackgroundSettings.panelBlurStrength,
                    builder: (context, value, _) {
                      return AppSettingSlider(
                        title: '模糊强度',
                        description: '0 = 无模糊，32 = 最强模糊',
                        value: value,
                        min: 0,
                        max: 32,
                        divisions: 32,
                        valueText: value == 0 ? '关闭' : value.toStringAsFixed(0),
                        onChanged: (next) {
                          AppBackgroundSettings.setPanelBlur(next);
                        },
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<bool>(
                valueListenable: AppBackgroundSettings.pageGlowEnabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '页面流光',
                    subtitle: enabled ? '页面顶部叠加主题色柔和渐变' : '关闭后页面仅使用主题背景',
                    value: enabled,
                    onChanged: (value) {
                      AppBackgroundSettings.setPageGlowEnabled(value);
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 导航设置：导航栏和播放条的透明度 + 液体玻璃，两条用同一组参数。
          AppCollapsibleSettingSection(
            title: '导航设置',
            children: [
              // 导航栏和播放条的透明度：玻璃模式下是底板的浓淡，普通模式下是
              // 底色的浓淡。显示「透明度」= 1 - 不透明度，往右越透。
              ValueListenableBuilder<double>(
                valueListenable: AppSurfaceSettings.barOpacity,
                builder: (context, opacity, _) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _InlineSlider(
                    title: '透明度',
                    value: 1 - opacity,
                    max: 0.95,
                    onChanged: (v) => AppSurfaceSettings.setBarOpacity(1 - v),
                  ),
                ),
              ),
              // 液体玻璃：与「高斯模糊」互斥。开启时各界面使用液体玻璃材质
              // （iOS 26 风格 shader 毛玻璃/高光/折射）并自动关闭高斯模糊；
              // 关闭后回退为下方「高斯模糊/模糊强度」控制的 BackdropFilter 方案。
              // TV 模式恒不生效（见 AppGlassSettings.effectiveEnabled）。
              ValueListenableBuilder<bool>(
                valueListenable: AppGlassSettings.liquidGlassEnabled,
                builder: (context, glassEnabled, _) {
                  return AppSettingSwitchTile(
                    title: '液体玻璃（导航栏 + 播放条）',
                    subtitle: glassEnabled
                        ? '导航栏和播放条用液体玻璃，下面调模糊、厚度'
                        : '关闭后导航栏和播放条用上面的高斯模糊或实色',
                    value: glassEnabled,
                    onChanged: (value) {
                      AppGlassSettings.setLiquidGlassEnabled(value);
                    },
                  );
                },
              ),
              // 玻璃参数：仅液体玻璃开启时显示，调节即时生效。
              ValueListenableBuilder<bool>(
                valueListenable: AppGlassSettings.liquidGlassEnabled,
                builder: (context, glassEnabled, _) {
                  if (!glassEnabled) return const SizedBox.shrink();
                  return Column(
                    children: [
                      const SizedBox(height: 8),
                      ValueListenableBuilder<double>(
                        valueListenable: AppGlassSettings.glassBlurStrength,
                        builder: (context, value, _) {
                          return AppSettingSlider(
                            title: '玻璃模糊强度',
                            description: '0 = 无模糊，16 = 最强模糊',
                            value: value,
                            min: 0,
                            max: 16,
                            divisions: 16,
                            valueText: value == 0
                                ? '关闭'
                                : value.toStringAsFixed(0),
                            onChanged: (next) {
                              AppGlassSettings.setGlassBlur(next);
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      ValueListenableBuilder<double>(
                        valueListenable: AppGlassSettings.glassThickness,
                        builder: (context, value, _) {
                          return AppSettingSlider(
                            title: '玻璃厚度',
                            description: '影响折射强度与边缘高光',
                            value: value,
                            min: 0,
                            max: 30,
                            divisions: 30,
                            valueText: value.toStringAsFixed(0),
                            onChanged: (next) {
                              AppGlassSettings.setGlassThickness(next);
                            },
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 边框与底色：所有能加框的单元共用一套（首页最新歌曲、歌曲列表、
          // 播放条、导航栏）。见 AppSurfaceSettings。
          AppCollapsibleSettingSection(
            title: '边框设置',
            children: [
              ValueListenableBuilder<SurfaceStyle>(
                valueListenable: AppSurfaceSettings.style,
                builder: (context, style, _) => _SurfaceStyleEditor(
                  style: style,
                  onChanged: AppSurfaceSettings.setStyle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「边框设置」：框的样式 → 框的颜色 → 框里面的底色 → 四个滑条
/// （框的深浅 / 框的厚度 / 框内深浅 / 框内厚度）。
/// 首页最新歌曲、歌曲列表、播放条、导航栏共用这一套。
class _SurfaceStyleEditor extends StatelessWidget {
  const _SurfaceStyleEditor({required this.style, required this.onChanged});

  final SurfaceStyle style;
  final ValueChanged<SurfaceStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    // 色板显示的默认色和实际画出来的一致（见 SurfacePaint）。
    final fillFallback = isDark ? scheme.surfaceContainerHighest : Colors.white;
    final frameFallback = isDark
        ? Colors.white.withValues(alpha: 0.32)
        : Colors.black.withValues(alpha: 0.28);
    return Column(
      children: [
        // 框的样式：三选一，不加框时底栏也不描边。
        ValueListenableBuilder<AppContentFrameStyle>(
          valueListenable: AppBackgroundSettings.contentFrameStyle,
          builder: (context, current, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '框的样式',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppContentFrameStyle>(
                    showSelectedIcon: false,
                    segments: [
                      for (final s in AppContentFrameStyle.values)
                        ButtonSegment(value: s, label: Text(s.label)),
                    ],
                    selected: {current},
                    onSelectionChanged: (sel) =>
                        AppSurfaceSettings.setFrameStyle(sel.first),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (style.frame)
          _ColorSettingTile(
            title: '框的颜色',
            color: style.frameColor ?? frameFallback,
            onPick: () => _showColorPickerDialog(
              context,
              initial: style.frameColor ?? frameFallback,
              onSelected: (c) => onChanged(
                c == null
                    ? style.copyWith(clearFrameColor: true)
                    : style.copyWith(frameColor: c),
              ),
            ),
            onReset: style.frameColor == null
                ? null
                : () => onChanged(style.copyWith(clearFrameColor: true)),
          ),
        _ColorSettingTile(
          title: '框里面的底色',
          color: style.color ?? fillFallback,
          onPick: () => _showColorPickerDialog(
            context,
            initial: style.color ?? fillFallback,
            onSelected: (c) => onChanged(
              c == null
                  ? style.copyWith(clearColor: true)
                  : style.copyWith(color: c),
            ),
          ),
          onReset: style.color == null
              ? null
              : () => onChanged(style.copyWith(clearColor: true)),
        ),
        const SizedBox(height: 4),
        if (style.frame) ...[
          _InlineSlider(
            title: '框的深浅',
            value: style.frameOpacity,
            min: 0.05,
            onChanged: (v) => onChanged(style.copyWith(frameOpacity: v)),
          ),
          _InlineSlider(
            title: '框的厚度',
            value: style.frameThickness,
            onChanged: (v) => onChanged(style.copyWith(frameThickness: v)),
          ),
        ],
        _InlineSlider(
          title: '框内深浅',
          value: style.opacity,
          min: 0.05,
          onChanged: (v) => onChanged(style.copyWith(opacity: v)),
        ),
        _InlineSlider(
          title: '框内厚度',
          value: style.thickness,
          onChanged: (v) => onChanged(style.copyWith(thickness: v)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 一行：标题 + 短滑条 + 百分比。不要说明文字，省地方。
class _InlineSlider extends StatelessWidget {
  const _InlineSlider({
    required this.title,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1.0,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: 76,
              child: Text(title, style: textTheme.bodyLarge),
            ),
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                '${(value * 100).round()}%',
                textAlign: TextAlign.end,
                style: textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 通用取色入口，复用主题色那套调色板对话框。
Future<void> _showColorPickerDialog(
  BuildContext context, {
  required Color initial,
  required ValueChanged<Color?> onSelected,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) =>
        _ThemeColorPickerDialog(initialColor: initial, onSelected: onSelected),
  );
}

/// 「颜色」设置条：右侧一块色卡，点击取色，长按恢复跟随主题。
class _ColorSettingTile extends StatelessWidget {
  final String title;
  final Color color;
  final VoidCallback onPick;

  /// 为 null 表示当前就是「跟随主题」，没有可恢复的东西。
  final VoidCallback? onReset;

  const _ColorSettingTile({
    required this.title,
    required this.color,
    required this.onPick,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: onReset,
      child: AppSettingTile(
        title: title,
        onTap: onPick,
        trailing: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }
}

class _ThemeColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onSelected;

  const _ThemeColorPickerDialog({
    required this.initialColor,
    required this.onSelected,
  });

  @override
  State<_ThemeColorPickerDialog> createState() =>
      _ThemeColorPickerDialogState();
}

class _ThemeColorPickerDialogState extends State<_ThemeColorPickerDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  void _updateSaturationValue(Offset localPosition, double size) {
    final dx = localPosition.dx.clamp(0.0, size);
    final dy = localPosition.dy.clamp(0.0, size);
    final saturation = (dx / size).clamp(0.0, 1.0);
    final value = (1 - dy / size).clamp(0.0, 1.0);
    setState(() {
      _hsv = _hsv.withSaturation(saturation).withValue(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _hsv.toColor();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('调色板', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: preview,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.maxWidth;
                  return GestureDetector(
                    onPanDown: (details) =>
                        _updateSaturationValue(details.localPosition, size),
                    onPanUpdate: (details) =>
                        _updateSaturationValue(details.localPosition, size),
                    child: Stack(
                      children: [
                        SizedBox(
                          width: size,
                          height: size,
                          child: CustomPaint(
                            painter: _SaturationValuePainter(hue: _hsv.hue),
                          ),
                        ),
                        Positioned(
                          left: _hsv.saturation * size - 10,
                          top: (1 - _hsv.value) * size - 10,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.onSurface,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _RainbowHueSlider(
                value: _hsv.hue,
                onChanged: (value) {
                  setState(() {
                    _hsv = _hsv.withHue(value);
                  });
                },
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.onSelected(preview);
                      Navigator.pop(context);
                    },
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  final double hue;

  _SaturationValuePainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final baseColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white, baseColor],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    final overlay = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(rect);
    canvas.drawRect(rect, overlay);
  }

  @override
  bool shouldRepaint(covariant _SaturationValuePainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}

class _RainbowHueSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _RainbowHueSlider({required this.value, required this.onChanged});

  @override
  State<_RainbowHueSlider> createState() => _RainbowHueSliderState();
}

class _RainbowHueSliderState extends State<_RainbowHueSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayValue = _dragValue ?? widget.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanDown: (details) => _updateValue(details.localPosition.dx, width),
          onPanUpdate: (details) =>
              _updateValue(details.localPosition.dx, width),
          onPanEnd: (_) => setState(() => _dragValue = null),
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFF0000),
                        Color(0xFFFFFF00),
                        Color(0xFF00FF00),
                        Color(0xFF00FFFF),
                        Color(0xFF0000FF),
                        Color(0xFFFF00FF),
                        Color(0xFFFF0000),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: (displayValue / 360 * width) - 10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: HSVColor.fromAHSV(1, displayValue, 1, 1).toColor(),
                      border: Border.all(color: scheme.onSurface, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _updateValue(double dx, double width) {
    final clamped = dx.clamp(0.0, width);
    final next = (clamped / width * 360).clamp(0.0, 360.0);
    setState(() {
      _dragValue = next;
    });
    widget.onChanged(next);
  }
}
