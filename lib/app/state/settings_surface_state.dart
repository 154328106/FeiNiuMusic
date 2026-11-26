import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../components/common/content_frame.dart';
import '../theme/app_glass_theme.dart';
import 'settings_background_state.dart';

/// 能加框的单元（最新歌曲、歌曲列表、播放条、导航栏）的外观。
@immutable
class SurfaceStyle {
  const SurfaceStyle({
    this.color,
    this.opacity = 0,
    this.thickness = 0,
    this.frame = true,
    this.frameColor,
    this.frameOpacity = 0.6,
    this.frameThickness = 0.4,
  });

  /// 框里面的底色。null = 跟随主题。
  final Color? color;

  /// 框内深浅（底色不透明度）0~1。0 = 完全透明。
  final double opacity;

  /// 框内厚度 0~1：投影深浅（0.5 = 原来的默认投影）。
  final double thickness;

  /// 是否加框。
  final bool frame;

  /// 框的颜色。null = 默认发丝色。
  final Color? frameColor;

  /// 框的深浅，乘在框颜色自带的透明度上。
  final double frameOpacity;

  /// 框的厚度 0~1 → 描边 0.5~3px（见 [SurfacePaint.frameWidth]）。
  final double frameThickness;

  SurfaceStyle copyWith({
    Color? color,
    bool clearColor = false,
    double? opacity,
    double? thickness,
    bool? frame,
    Color? frameColor,
    bool clearFrameColor = false,
    double? frameOpacity,
    double? frameThickness,
  }) {
    return SurfaceStyle(
      color: clearColor ? null : (color ?? this.color),
      opacity: opacity ?? this.opacity,
      thickness: thickness ?? this.thickness,
      frame: frame ?? this.frame,
      frameColor: clearFrameColor ? null : (frameColor ?? this.frameColor),
      frameOpacity: frameOpacity ?? this.frameOpacity,
      frameThickness: frameThickness ?? this.frameThickness,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': color?.toARGB32(),
    'opacity': opacity,
    'thickness': thickness,
    'frame': frame,
    'frameColor': frameColor?.toARGB32(),
    'frameOpacity': frameOpacity,
    'frameThickness': frameThickness,
  };

  static SurfaceStyle fromJson(Map<String, dynamic> j) {
    double d(String k, double def) =>
        ((j[k] as num?)?.toDouble() ?? def).clamp(0.0, 1.0);
    final c = j['color'];
    final fc = j['frameColor'];
    return SurfaceStyle(
      color: c is int ? Color(c) : null,
      opacity: d('opacity', 0),
      thickness: d('thickness', 0),
      frame: j['frame'] is bool ? j['frame'] as bool : true,
      frameColor: fc is int ? Color(fc) : null,
      frameOpacity: d('frameOpacity', 0.6),
      frameThickness: d('frameThickness', 0.4),
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
      other.frameOpacity == frameOpacity &&
      other.frameThickness == frameThickness;

  @override
  int get hashCode => Object.hash(
    color,
    opacity,
    thickness,
    frame,
    frameColor,
    frameOpacity,
    frameThickness,
  );
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

  static const _prefsBarOpacity = 'surface_bar_opacity';
  // 默认值改过一次。只把「还停在上一版出厂值」的安装迁过来，手调过的不动。
  static const _prefsDefaultsRev = 'surface_style_defaults_rev';
  static const _defaultsRev = 1;

  /// 新装出厂：白底、蓝框。深浅见构造默认（框 60%/40%，框内 0%/0%）。
  static const SurfaceStyle freshDefault = SurfaceStyle(
    color: Colors.white,
    frame: true,
    frameColor: Color(0xFF377BEA),
  );

  static final ValueNotifier<SurfaceStyle> style = ValueNotifier(
    const SurfaceStyle(frame: false),
  );

  /// 导航栏 + 播放条自己的不透明度（「导航设置 → 透明度」= 1 - 这个值）。
  /// 玻璃模式下就是垫在玻璃下面那块白/黑底板的浓淡。和「框内深浅」分开：
  /// 列表卡片想实一点、底栏想透一点，是常见搭配。0 = 透明度 100%。
  static final ValueNotifier<double> barOpacity = ValueNotifier(0);

  static Future<void>? _loading;
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    await AppBackgroundSettings.ensureLoaded();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsStyle);
      bool listFramed() =>
          AppBackgroundSettings.contentFrameStyle.value !=
          AppContentFrameStyle.none;
      // 旧版导航栏 / 内容框设置一项都没存过 = 新装用户。
      const oldKeys = [
        'setting_nav_bar_color',
        'setting_nav_bar_opacity',
        'setting_nav_bar_frame_enabled',
        'setting_nav_bar_frame_color',
        'setting_nav_bar_frame_opacity',
        'setting_content_frame_style',
        _prefsOldThickness,
      ];
      final isFreshInstall = !oldKeys.any(prefs.containsKey);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) style.value = SurfaceStyle.fromJson(j.cast());
      } else if (isFreshInstall) {
        // 新装默认：逐行卡片、蓝框、白底。深浅用 [freshDefault]。
        await AppBackgroundSettings.setContentFrameStyle(
          AppContentFrameStyle.cards,
        );
        style.value = freshDefault;
        await prefs.setString(_prefsStyle, jsonEncode(style.value.toJson()));
        await prefs.setInt(_prefsDefaultsRev, _defaultsRev);
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
          frame: listFramed(),
          frameColor:
              AppBackgroundSettings.navBarFrameColor.value ??
              AppBackgroundSettings.contentFrameColor.value,
          frameOpacity: AppBackgroundSettings.navBarFrameOpacity.value,
        );
      }
      // 「加框」以列表的加框方式为准，两边对齐。
      if (style.value.frame != listFramed()) {
        style.value = style.value.copyWith(frame: listFramed());
      }
      final rev = prefs.getInt(_prefsDefaultsRev) ?? 0;
      if (rev < _defaultsRev) {
        if (_isPreviousFactoryDefault(style.value)) {
          // 上一版出厂深浅：框 25%/35%、框内 50%/50%（或更早的 85%/50%/50%/28%）。
          style.value = style.value.copyWith(
            opacity: freshDefault.opacity,
            thickness: freshDefault.thickness,
            frameOpacity: freshDefault.frameOpacity,
            frameThickness: freshDefault.frameThickness,
          );
          await prefs.setString(_prefsStyle, jsonEncode(style.value.toJson()));
          final savedBar = prefs.getDouble(_prefsBarOpacity);
          // 底栏透明度以前跟着框内深浅，或停在旧默认 85%。这两种一并改成 100%。
          if (savedBar == null ||
              _near(savedBar, 0.5) ||
              _near(savedBar, 0.85)) {
            await prefs.setDouble(_prefsBarOpacity, 0);
          }
        }
        await prefs.setInt(_prefsDefaultsRev, _defaultsRev);
      }
      // 第一次没存过：沿用框内深浅，升级后底栏外观不变。
      barOpacity.value =
          (prefs.getDouble(_prefsBarOpacity) ?? style.value.opacity).clamp(
            0.0,
            1.0,
          );
    } catch (_) {
      // 读坏了就用默认值，别卡启动。
    }
  }

  /// 底部栏（播放条 + 导航）用的样式。
  /// 颜色、框跟「边框设置」走，深浅用自己的 [barOpacity]。
  static SurfaceStyle get bottomBar =>
      style.value.copyWith(opacity: barOpacity.value);

  /// 列表与卡片用的样式。
  static SurfaceStyle get contentStyle => style.value;

  static final Listenable bottomBarListenable = Listenable.merge([
    style,
    barOpacity,
  ]);

  static bool _near(double a, double b) => (a - b).abs() < 0.001;

  /// 还停在上一版写死的出厂滑条上（颜色可以是当时的白底蓝框，或更早的未改色）。
  static bool _isPreviousFactoryDefault(SurfaceStyle s) {
    final previousFresh =
        s.color == Colors.white &&
        s.frameColor == const Color(0xFF377BEA) &&
        _near(s.opacity, 0.5) &&
        _near(s.thickness, 0.5) &&
        _near(s.frameOpacity, 0.25) &&
        _near(s.frameThickness, 0.35);
    final previousCtor =
        _near(s.opacity, 0.85) &&
        _near(s.thickness, 0.5) &&
        _near(s.frameOpacity, 0.5) &&
        _near(s.frameThickness, 0.28);
    return previousFresh || previousCtor;
  }

  static Future<void> setBarOpacity(double v) async {
    final next = v.clamp(0.0, 1.0);
    barOpacity.value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefsBarOpacity, next);
    } catch (_) {}
  }

  /// 框的样式：不加框 / 整块描边 / 逐行卡片。同时决定底栏描不描边。
  static Future<void> setFrameStyle(AppContentFrameStyle s) async {
    await AppBackgroundSettings.setContentFrameStyle(s);
    final framed = s != AppContentFrameStyle.none;
    if (framed != style.value.frame) {
      await setStyle(style.value.copyWith(frame: framed));
    }
  }

  static Future<void> setStyle(SurfaceStyle s) async {
    // 调「框内深浅」= 一键同步所有地方：导航栏和播放条的透明度跟着走。
    // 之后想让底栏单独更透，再去「导航设置 → 透明度」调（那个只管底栏）。
    if (s.opacity != style.value.opacity) await setBarOpacity(s.opacity);
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

  /// 玻璃本身的着色：固定一半浓度，**不跟透明度走**。
  ///
  /// 「导航设置 → 透明度」只该让底栏变通透，不该把颜色洗白。以前着色也乘了
  /// opacity，一调透明，玻璃自己的白雾 / 去饱和就盖过底色，看着像换了颜色。
  /// 现在透明度只淡化下面那层底板，颜色由这层着色撑住。
  static Color? glassTint(SurfaceStyle s) => s.color?.withValues(alpha: 0.5);

  /// 玻璃模式下垫在玻璃后面的底板（深浅跟着 opacity 走）。
  static Color glassPlate(BuildContext context, SurfaceStyle s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final def = appGlassPlateColor(isDark);
    // 自定义了底色就用它垫底板（透明度沿用默认底板那一档）：以前底板写死
    // 白/黑，只有导航的玻璃着色吃底色，播放条改色看不出变化。
    final base = s.color?.withValues(alpha: def.a) ?? def;
    return base.withValues(alpha: (base.a * s.opacity).clamp(0.0, 1.0));
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

  /// 描边宽度（「框的厚度」）：0.5 ~ 3px，默认 0.28 ≈ 原来的 1.2px。
  static double frameWidth(SurfaceStyle s) => 0.5 + 2.5 * s.frameThickness;

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
