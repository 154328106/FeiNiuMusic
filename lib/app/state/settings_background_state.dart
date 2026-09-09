import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../components/common/content_frame.dart';
import 'settings_glass_state.dart';

class AppBackgroundSettings {
  static const String _prefsBackgroundImagePath =
      'setting_background_image_path';
  static const String _prefsBackgroundMaskOpacity =
      'setting_background_mask_opacity';
  static const String _prefsBackgroundBlurSigma =
      'setting_background_blur_sigma';
  static const String _prefsPageGlowEnabled = 'setting_page_glow_enabled';
  static const String _prefsPanelBlur = 'setting_panel_blur';
  static const String _prefsPanelBlurEnabled = 'setting_panel_blur_enabled';
  static const String _prefsContentFrame = 'setting_content_frame_enabled';
  static const String _prefsContentFrameStyle = 'setting_content_frame_style';
  static const String _prefsContentFrameColor = 'setting_content_frame_color';
  static const String _prefsContentFrameOpacity =
      'setting_content_frame_opacity';
  static const String _prefsNavBarColor = 'setting_nav_bar_color';
  static const String _prefsNavBarOpacity = 'setting_nav_bar_opacity';
  static const String _prefsMiniPlayerOnlyWhilePlaying =
      'setting_mini_player_only_while_playing';
  static const String _prefsNavBarFrameEnabled =
      'setting_nav_bar_frame_enabled';
  static const String _prefsNavBarFrameColor = 'setting_nav_bar_frame_color';
  static const String _prefsNavBarFrameOpacity =
      'setting_nav_bar_frame_opacity';

  static final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);
  static final ValueNotifier<double> backgroundMaskOpacity = ValueNotifier(
    0.35,
  );
  // 0 = original sharp image, 32 = heavily blurred. Users kept complaining
  // that "透明度=0" still looked hazy — that was this constant-16 blur.
  static final ValueNotifier<double> backgroundBlurSigma = ValueNotifier(16);
  static final ValueNotifier<bool> pageGlowEnabled = ValueNotifier(false);
  /// 面板高斯模糊强度（0 = 无模糊，32 = 最大模糊）
  static final ValueNotifier<double> panelBlurStrength = ValueNotifier(20);
  /// 高斯模糊总开关。关闭后 [panelBlurStrength] 视为 0，各处不渲染模糊。
  /// 高斯模糊总开关。关闭后 [panelBlurStrength] 视为 0，各处不渲染模糊。
  ///
  /// 默认关：模糊在低端机上掉帧，而且开了之后底栏底色被压到很淡（见
  /// modern_navigation_bar 里的 isBlurred 分支），观感反而糊。
  static final ValueNotifier<bool> panelBlurEnabled = ValueNotifier(false);

  /// 列表加框样式。见 [AppContentFrameStyle]（不加框 / 整块描边 / 逐行卡片）。
  /// 用字符串存，避免枚举顺序变化影响已保存的值。
  static final ValueNotifier<AppContentFrameStyle> contentFrameStyle =
      ValueNotifier(AppContentFrameStyle.cards);

  /// 描边自定义颜色。null = 跟随主题（scheme.outlineVariant）。
  static final ValueNotifier<Color?> contentFrameColor = ValueNotifier(null);

  /// 描边不透明度 0~1。
  ///
  /// 默认 0.15：配合「逐行卡片」时描边只是给每行一个若有若无的轮廓，
  /// 太重会让整页变成一堆方框。
  static final ValueNotifier<double> contentFrameOpacity = ValueNotifier(0.15);

  /// 底部导航栏自定义底色。null = 跟随主题。
  static final ValueNotifier<Color?> navBarColor = ValueNotifier(null);

  /// 底部导航栏底色深浅度（不透明度）0~1。
  static final ValueNotifier<double> navBarOpacity = ValueNotifier(1.0);

  /// 底部导航栏是否描边。普通分支与液体玻璃分支共用。
  static final ValueNotifier<bool> navBarFrameEnabled = ValueNotifier(true);

  /// 底栏描边颜色。null = 用默认的发丝色（亮/暗各一档）。
  static final ValueNotifier<Color?> navBarFrameColor = ValueNotifier(null);

  /// 底栏描边深浅度（不透明度）0~1，乘在描边颜色自带的 alpha 上。
  ///
  /// 默认发丝色本身就是半透明的（浅色 28% / 深色 32%），所以这里是「在默认
  /// 基础上再淡多少」，1.0 = 默认那档，不是纯色。
  static final ValueNotifier<double> navBarFrameOpacity = ValueNotifier(1.0);

  /// 迷你播放条仅在播放时显示，暂停/停止时隐藏。
  ///
  /// 注意：开启后暂停就看不到这条，想恢复播放得进播放页或从列表点。
  static final ValueNotifier<bool> miniPlayerOnlyWhilePlaying = ValueNotifier(
    false,
  );

  /// 生效的高斯模糊强度：总开关关闭时恒为 0。
  static double get effectivePanelBlur {
    return panelBlurEnabled.value ? panelBlurStrength.value : 0.0;
  }

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    backgroundImagePath.value = prefs.getString(_prefsBackgroundImagePath);
    backgroundMaskOpacity.value =
        (prefs.getDouble(_prefsBackgroundMaskOpacity) ?? 0.5).clamp(0.0, 1.0);
    backgroundBlurSigma.value =
        (prefs.getDouble(_prefsBackgroundBlurSigma) ?? 16).clamp(0.0, 32.0);
    pageGlowEnabled.value = prefs.getBool(_prefsPageGlowEnabled) ?? false;
    panelBlurStrength.value = (prefs.getDouble(_prefsPanelBlur) ?? 20).clamp(0.0, 32.0);
    panelBlurEnabled.value = prefs.getBool(_prefsPanelBlurEnabled) ?? false;
    final rawFrame = prefs.getString(_prefsContentFrameStyle);
    contentFrameStyle.value = rawFrame != null
        ? AppContentFrameStyle.fromName(rawFrame)
        // 上一版是个布尔开关，按它迁移一次。
        //
        // 注意这里的兜底才是真正生效的默认值 —— 字段声明处的 ValueNotifier
        // 初始值启动时会被这一行覆盖，只改那边等于没改。
        : ((prefs.getBool(_prefsContentFrame) ?? false)
              ? AppContentFrameStyle.outlined
              : AppContentFrameStyle.cards);
    final frameColor = prefs.getInt(_prefsContentFrameColor);
    contentFrameColor.value = frameColor == null ? null : Color(frameColor);
    contentFrameOpacity.value =
        (prefs.getDouble(_prefsContentFrameOpacity) ?? 0.15).clamp(0.0, 1.0);
    final navColor = prefs.getInt(_prefsNavBarColor);
    navBarColor.value = navColor == null ? null : Color(navColor);
    navBarOpacity.value =
        (prefs.getDouble(_prefsNavBarOpacity) ?? 1.0).clamp(0.0, 1.0);
    navBarFrameEnabled.value =
        prefs.getBool(_prefsNavBarFrameEnabled) ?? true;
    navBarFrameOpacity.value =
        (prefs.getDouble(_prefsNavBarFrameOpacity) ?? 1.0).clamp(0.0, 1.0);
    final navFrameColor = prefs.getInt(_prefsNavBarFrameColor);
    navBarFrameColor.value =
        navFrameColor == null ? null : Color(navFrameColor);
    miniPlayerOnlyWhilePlaying.value =
        prefs.getBool(_prefsMiniPlayerOnlyWhilePlaying) ?? false;
  }

  static Future<void> setBackgroundImagePath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_prefsBackgroundImagePath);
      backgroundImagePath.value = null;
      return;
    }
    await prefs.setString(_prefsBackgroundImagePath, path);
    backgroundImagePath.value = path;
  }

  static Future<void> setBackgroundMaskOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 1.0);
    await prefs.setDouble(_prefsBackgroundMaskOpacity, next);
    backgroundMaskOpacity.value = next;
  }

  static Future<void> setBackgroundBlurSigma(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 32.0);
    await prefs.setDouble(_prefsBackgroundBlurSigma, next);
    backgroundBlurSigma.value = next;
  }

  static Future<void> setPageGlowEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsPageGlowEnabled, enabled);
    pageGlowEnabled.value = enabled;
  }

  static Future<void> setPanelBlur(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 32.0);
    await prefs.setDouble(_prefsPanelBlur, next);
    panelBlurStrength.value = next;
  }

  /// [color] 传 null 表示恢复「跟随主题」。
  static Future<void> setContentFrameColor(Color? color) async {
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_prefsContentFrameColor);
    } else {
      await prefs.setInt(_prefsContentFrameColor, color.toARGB32());
    }
    contentFrameColor.value = color;
  }

  static Future<void> setContentFrameOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final v = value.clamp(0.0, 1.0);
    await prefs.setDouble(_prefsContentFrameOpacity, v);
    contentFrameOpacity.value = v;
  }

  static Future<void> setNavBarColor(Color? color) async {
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_prefsNavBarColor);
    } else {
      await prefs.setInt(_prefsNavBarColor, color.toARGB32());
    }
    navBarColor.value = color;
  }

  static Future<void> setMiniPlayerOnlyWhilePlaying(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsMiniPlayerOnlyWhilePlaying, value);
    miniPlayerOnlyWhilePlaying.value = value;
  }

  static Future<void> setNavBarOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final v = value.clamp(0.0, 1.0);
    await prefs.setDouble(_prefsNavBarOpacity, v);
    navBarOpacity.value = v;
  }

  static Future<void> setNavBarFrameColor(Color? color) async {
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_prefsNavBarFrameColor);
    } else {
      await prefs.setInt(_prefsNavBarFrameColor, color.toARGB32());
    }
    navBarFrameColor.value = color;
  }

  static Future<void> setNavBarFrameOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final v = value.clamp(0.0, 1.0);
    await prefs.setDouble(_prefsNavBarFrameOpacity, v);
    navBarFrameOpacity.value = v;
  }

  static Future<void> setNavBarFrameEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsNavBarFrameEnabled, enabled);
    navBarFrameEnabled.value = enabled;
  }

  static Future<void> setContentFrameStyle(AppContentFrameStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsContentFrameStyle, style.name);
    contentFrameStyle.value = style;
  }

  static Future<void> setPanelBlurEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsPanelBlurEnabled, enabled);
    panelBlurEnabled.value = enabled;
    // 与液体玻璃互斥：开启高斯模糊时关闭液体玻璃。
    if (enabled) {
      await AppGlassSettings.setLiquidGlassEnabled(false);
    }
  }
}
