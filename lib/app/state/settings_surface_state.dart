import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../components/common/content_frame.dart';
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

/// 「边框与底色」：所有能加框的单元（首页最新歌曲、歌曲列表、播放条、导航栏）
/// 共用**一套**样式，一个开关、一组色板和滑块。
///
/// 「加框」开关同时管列表的加框方式：关 = 列表不加框、两条底栏不描边；
/// 开 = 列表按「整块描边 / 逐行卡片」出框、底栏描边。两边永远一致。
class AppSurfaceSettings {
  AppSurfaceSettings._();

  static const _prefsStyle = 'surface_style_unified';
  // 旧版（导航栏单独一组设置时代）存的厚度，迁移时读一次。
  static const _prefsOldThickness = 'surface_bottom_thickness';

  static final ValueNotifier<SurfaceStyle> style = ValueNotifier(
    const SurfaceStyle(frame: false),
  );

  static Future<void>? _loading;
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    await AppBackgroundSettings.ensureLoaded();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsStyle);
      final listFramed =
          AppBackgroundSettings.contentFrameStyle.value !=
          AppContentFrameStyle.none;
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) style.value = SurfaceStyle.fromJson(j.cast());
      } else {
        // 第一次：从原来的导航栏设置迁移过来，老用户调过的颜色不丢。
        // 描边颜色导航没设就拿原「内容框」的。
        style.value = SurfaceStyle(
          color: AppBackgroundSettings.navBarColor.value,
          opacity: AppBackgroundSettings.navBarOpacity.value,
          thickness: (prefs.getDouble(_prefsOldThickness) ?? 0.5).clamp(
            0.0,
            1.0,
          ),
          frame: listFramed,
          frameColor:
              AppBackgroundSettings.navBarFrameColor.value ??
              AppBackgroundSettings.contentFrameColor.value,
          frameOpacity: AppBackgroundSettings.navBarFrameOpacity.value,
        );
      }
      // 「加框」以列表的加框方式为准，两边对齐。
      if (style.value.frame != listFramed) {
        style.value = style.value.copyWith(frame: listFramed);
      }
    } catch (_) {
      // 读坏了就用默认值，别卡启动。
    }
  }

  /// 底部栏（播放条 + 导航）用的样式。
  static SurfaceStyle get bottomBar => style.value;

  /// 列表与卡片用的样式。
  static SurfaceStyle get contentStyle => style.value;

  static Listenable get bottomBarListenable => style;

  /// 框的样式：不加框 / 整块描边 / 逐行卡片。同时决定底栏描不描边。
  static Future<void> setFrameStyle(AppContentFrameStyle s) async {
    await AppBackgroundSettings.setContentFrameStyle(s);
    final framed = s != AppContentFrameStyle.none;
    if (framed != style.value.frame) {
      await setStyle(style.value.copyWith(frame: framed));
    }
  }

  static Future<void> setStyle(SurfaceStyle s) async {
    style.value = s;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsStyle, jsonEncode(s.toJson()));
    } catch (_) {}
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
    final def = appGlassPlateColor(isDark);
    // 自定义了底色就用它垫底板（透明度沿用默认底板那一档）：以前底板写死
    // 白/黑，只有导航的玻璃着色吃底色，播放条改色看不出变化。
    final base = s.color?.withValues(alpha: def.a) ?? def;
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
  ///
  /// [scale] 整体缩小投影：列表行、卡片是一大片，用底栏那么重的投影会糊成一团。
  static List<BoxShadow> shadow(
    BuildContext context,
    SurfaceStyle s, {
    double scale = 1.0,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final k = s.thickness * 2; // 0 ~ 2
    if (k <= 0) return const [];
    return [
      BoxShadow(
        color: Colors.black.withValues(
          alpha: ((isDark ? 0.40 : 0.20) * s.opacity * k * scale).clamp(
            0.0,
            1.0,
          ),
        ),
        blurRadius: (10 + 10 * k) * scale,
        offset: Offset(0, (2 + 4 * k) * scale),
      ),
    ];
  }
}
