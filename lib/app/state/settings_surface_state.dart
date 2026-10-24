import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_glass_theme.dart';
import 'settings_background_state.dart';
import 'settings_glass_state.dart';

/// 一块「表面」（底栏、卡片…）的外观：底色、深浅、厚度、描边。
///
/// 统一管理外观的基础：每个区域（底部栏 / 列表卡片 / 首页…）用同一套参数，
/// 可以各自调，也可以「跟随全局」。
@immutable
class SurfaceStyle {
  const SurfaceStyle({
    this.color,
    this.opacity = 0.85,
    this.thickness = 0.5,
    this.frame = true,
    this.frameColor,
    this.frameOpacity = 0.5,
  });

  /// 底色。null = 跟随主题。
  final Color? color;

  /// 底色深浅（不透明度）0.05~1。
  final double opacity;

  /// 厚度 0~1：普通模式下是投影深浅（0.5 = 原来的默认投影）。
  final double thickness;

  /// 是否描边。
  final bool frame;

  /// 描边颜色。null = 默认发丝色。
  final Color? frameColor;

  /// 描边深浅，乘在描边颜色自带的透明度上。
  final double frameOpacity;

  SurfaceStyle copyWith({
    Color? color,
    bool clearColor = false,
    double? opacity,
    double? thickness,
    bool? frame,
    Color? frameColor,
    bool clearFrameColor = false,
    double? frameOpacity,
  }) {
    return SurfaceStyle(
      color: clearColor ? null : (color ?? this.color),
      opacity: opacity ?? this.opacity,
      thickness: thickness ?? this.thickness,
      frame: frame ?? this.frame,
      frameColor: clearFrameColor ? null : (frameColor ?? this.frameColor),
      frameOpacity: frameOpacity ?? this.frameOpacity,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': color?.toARGB32(),
    'opacity': opacity,
    'thickness': thickness,
    'frame': frame,
    'frameColor': frameColor?.toARGB32(),
    'frameOpacity': frameOpacity,
  };

  static SurfaceStyle fromJson(Map<String, dynamic> j) {
    double d(String k, double def) =>
        ((j[k] as num?)?.toDouble() ?? def).clamp(0.0, 1.0);
    final c = j['color'];
    final fc = j['frameColor'];
    return SurfaceStyle(
      color: c is int ? Color(c) : null,
      opacity: d('opacity', 0.85),
      thickness: d('thickness', 0.5),
      frame: j['frame'] is bool ? j['frame'] as bool : true,
      frameColor: fc is int ? Color(fc) : null,
      frameOpacity: d('frameOpacity', 0.5),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SurfaceStyle &&
      other.color == color &&
      other.opacity == opacity &&
      other.thickness == thickness &&
      other.frame == frame &&
      other.frameColor == frameColor &&
      other.frameOpacity == frameOpacity;

  @override
  int get hashCode =>
      Object.hash(color, opacity, thickness, frame, frameColor, frameOpacity);
}

/// 统一外观设置。
///
/// - 全局样式：各区域默认跟随它。
/// - 底部栏（播放条 + 底部导航）：两条永远用同一套样式。它「自己的」样式直接
///   存在原来那几个导航栏设置里（底色/深浅/描边/描边色/描边深浅），只新增了
///   「厚度」—— 老用户的设置原样就是底部栏的值，升级后外观不变。
class AppSurfaceSettings {
  AppSurfaceSettings._();

  static const _prefsGlobal = 'surface_style_global';
  static const _prefsBottomFollow = 'surface_bottom_follow_global';
  static const _prefsBottomThickness = 'surface_bottom_thickness';

  static final ValueNotifier<SurfaceStyle> global = ValueNotifier(
    const SurfaceStyle(),
  );

  /// 底部栏是否跟随全局。默认 false：保留老用户在导航栏上调过的样式。
  static final ValueNotifier<bool> bottomBarFollowGlobal = ValueNotifier(false);

  /// 底部栏自己的厚度（其余字段在 AppBackgroundSettings.navBar* 里）。
  static final ValueNotifier<double> bottomBarThickness = ValueNotifier(0.5);

  static Future<void>? _loading;
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    await AppBackgroundSettings.ensureLoaded();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsGlobal);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) global.value = SurfaceStyle.fromJson(j.cast());
      }
      bottomBarFollowGlobal.value = prefs.getBool(_prefsBottomFollow) ?? false;
      bottomBarThickness.value = (prefs.getDouble(_prefsBottomThickness) ?? 0.5)
          .clamp(0.0, 1.0);
    } catch (_) {
      // 读坏了就用默认值，别卡启动。
    }
  }

  /// 底部栏自己的样式（来自原导航栏设置 + 厚度）。
  static SurfaceStyle get bottomBarOwn => SurfaceStyle(
    color: AppBackgroundSettings.navBarColor.value,
    opacity: AppBackgroundSettings.navBarOpacity.value,
    thickness: bottomBarThickness.value,
    frame: AppBackgroundSettings.navBarFrameEnabled.value,
    frameColor: AppBackgroundSettings.navBarFrameColor.value,
    frameOpacity: AppBackgroundSettings.navBarFrameOpacity.value,
  );

  /// 底部栏实际生效的样式。
  static SurfaceStyle get bottomBar =>
      bottomBarFollowGlobal.value ? global.value : bottomBarOwn;

  /// 底部栏样式相关的所有可监听项（导航条 / 播放条重建用）。
  static final Listenable bottomBarListenable = Listenable.merge([
    global,
    bottomBarFollowGlobal,
    bottomBarThickness,
    AppBackgroundSettings.navBarColor,
    AppBackgroundSettings.navBarOpacity,
    AppBackgroundSettings.navBarFrameEnabled,
    AppBackgroundSettings.navBarFrameColor,
    AppBackgroundSettings.navBarFrameOpacity,
  ]);

  static Future<void> setGlobal(SurfaceStyle s) async {
    global.value = s;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsGlobal, jsonEncode(s.toJson()));
    } catch (_) {}
  }

  static Future<void> setBottomBarFollowGlobal(bool v) async {
    bottomBarFollowGlobal.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsBottomFollow, v);
    } catch (_) {}
  }

  /// 写底部栏自己的样式：各字段落到原导航栏设置里，厚度单独存。
  static Future<void> setBottomBarOwn(SurfaceStyle s) async {
    final old = bottomBarOwn;
    if (s.color != old.color)
      await AppBackgroundSettings.setNavBarColor(s.color);
    if (s.opacity != old.opacity) {
      await AppBackgroundSettings.setNavBarOpacity(s.opacity);
    }
    if (s.frame != old.frame) {
      await AppBackgroundSettings.setNavBarFrameEnabled(s.frame);
    }
    if (s.frameColor != old.frameColor) {
      await AppBackgroundSettings.setNavBarFrameColor(s.frameColor);
    }
    if (s.frameOpacity != old.frameOpacity) {
      await AppBackgroundSettings.setNavBarFrameOpacity(s.frameOpacity);
    }
    if (s.thickness != old.thickness) {
      bottomBarThickness.value = s.thickness;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_prefsBottomThickness, s.thickness);
      } catch (_) {}
    }
  }
}

/// 把 [SurfaceStyle] 落成具体颜色 / 描边 / 投影。底部导航条和播放条都用这里，
/// 同一套算法 → 两条永远一致。
class SurfacePaint {
  SurfacePaint._();

  /// 底色。[blurred] = 开了高斯模糊：底色要淡（靠模糊出效果），但留个下限，
  /// 否则页面背景是纯色时模糊等于没模糊，底栏会整个消失。
  static Color fill(
    BuildContext context,
    SurfaceStyle s, {
    bool blurred = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 未自定义时跟「逐行卡片」同色；不能用 surface：页面背景本身就是 surface。
    final tint =
        s.color ?? (isDark ? scheme.surfaceContainerHighest : Colors.white);
    return blurred
        ? tint.withValues(alpha: (0.28 * s.opacity).clamp(0.0, 1.0))
        : tint.withValues(alpha: s.opacity);
  }

  /// 玻璃模式下垫在玻璃后面的底板（深浅跟着 opacity 走）。
  static Color glassPlate(BuildContext context, SurfaceStyle s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = appGlassPlateColor(isDark);
    // 透镜模式：底板只留一丝，不然玻璃折射的是底板而不是后面的内容。
    final lens = AppGlassSettings.glassLens.value ? 0.12 : 1.0;
    return base.withValues(
      alpha: (base.a * s.opacity * lens).clamp(0.0, 1.0),
    );
  }

  /// 描边颜色；不描边返回 null。[fallback] = 没自定义时的默认色（玻璃底板有
  /// 自己的一档默认），不给就用默认发丝色。
  static Color? frameColor(
    BuildContext context,
    SurfaceStyle s, {
    Color? fallback,
  }) {
    if (!s.frame) return null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final def =
        fallback ??
        (isDark
            ? Colors.white.withValues(alpha: 0.32)
            : Colors.black.withValues(alpha: 0.28));
    final base = s.frameColor ?? def;
    return base.withValues(alpha: (base.a * s.frameOpacity).clamp(0.0, 1.0));
  }

  /// 描边宽度：自定义颜色时略粗，不然调了颜色也看不出来。
  static double frameWidth(SurfaceStyle s) => s.frameColor == null ? 1.2 : 1.6;

  /// 投影：深浅跟着「厚度」和底色深浅走。厚度 0.5 = 原来的默认投影。
  static List<BoxShadow> shadow(BuildContext context, SurfaceStyle s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final k = s.thickness * 2; // 0 ~ 2
    if (k <= 0) return const [];
    return [
      BoxShadow(
        color: Colors.black.withValues(
          alpha: ((isDark ? 0.40 : 0.20) * s.opacity * k).clamp(0.0, 1.0),
        ),
        blurRadius: 10 + 10 * k,
        offset: Offset(0, 2 + 4 * k),
      ),
    ];
  }
}
