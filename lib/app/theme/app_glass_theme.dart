import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../state/settings_state.dart';

/// 统一的玻璃表面观感（与底栏 [GlassTabBar.bottom] 内部校准值一致）。
///
/// 作为底栏显式传入的完整参数；同时 [appGlassTheme] 用同一组字段构造
/// theme 覆盖，保证所有继承 GlassTheme 的玻璃表面（迷你播放器 / 设置面板 /
/// 弹窗 / sheet / 交互件）与底栏完全同步：
/// - `thickness: 30` —— 深折射，玻璃后的图标/文字有明显光学位移；
/// - `blur: 3` —— 轻底色模糊（折射主导，而非单纯的毛玻璃）；
/// - `glassColor: 白 24%` —— 底栏校准的着色；
/// - 其余（光照角度 135°、折射率 1.59、饱和度 0.7、色差 0.3 等）同为底栏数值。
const LiquidGlassSettings kAppGlassSurfaceSettings = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  chromaticAberration: 0.3,
  lightIntensity: 0.6,
  refractiveIndex: 1.59,
  saturation: 0.7,
  ambientStrength: 1,
  lightAngle: 0.75 * math.pi,
  glassColor: Color(0x3DFFFFFF),
);

/// 构建 App 全局液体玻璃主题。
///
/// **重要**：theme 的表面字段**必须直接以底栏完整参数构造**，不能从包推荐
/// [GlassThemeVariant.light/dark.settings] `copyWith` 派生——包推荐 base 带
/// 额外的「通透」字段（whitenStrength / fresnelStrength / edgeAbsorption 等），
/// 会混进继承 theme 的表面容器，造成它们与底栏（LiquidGlassSettings 全默认
/// base）观感不一致（表现为迷你播放器等「像高斯模糊、不通透」）。
///
/// 这里用与 [kAppGlassSurfaceSettings] 相同的字段构造 partial override，
/// `applyTo(默认 base)` 后即与底栏完全一致；再叠加用户可调的模糊强度 / 厚度
/// （[AppGlassSettings]，默认即底栏数值 blur 3 / thickness 30）。辉光主色
/// [seed] 跟随 App 主题种子色。
GlassThemeData appGlassTheme(Color seed) {
  final blur = AppGlassSettings.glassBlurStrength.value;
  final thickness = AppGlassSettings.glassThickness.value;

  // 与 kAppGlassSurfaceSettings 同字段的 partial override（不继承包推荐 base）。
  GlassThemeSettings surfaceFor() => const GlassThemeSettings(
    thickness: 30,
    blur: 3,
    chromaticAberration: 0.3,
    lightIntensity: 0.6,
    refractiveIndex: 1.59,
    saturation: 0.7,
    ambientStrength: 1,
    lightAngle: 0.75 * math.pi,
    glassColor: Color(0x3DFFFFFF),
  ).copyWith(
    blur: blur,
    thickness: thickness,
  );

  return GlassThemeData(
    // 显式固定 quality：quality=null 时各 widget 默认 premium（重 multi-pass
    // shader + blend group），在 Skia（macOS/Windows 3.44 默认渲染器）上滚动时
    // 逐帧重采样开销大。standard 为桌面端推荐档：单一轻量 shader，观感一致
    // 且稳定，杜绝滚动黑屏闪烁。
    light: GlassThemeVariant.light.copyWith(
      settings: surfaceFor(),
      glowColors: GlassGlowColors(primary: seed),
      quality: GlassQuality.standard,
    ),
    dark: GlassThemeVariant.dark.copyWith(
      settings: surfaceFor(),
      glowColors: GlassGlowColors(primary: seed),
      quality: GlassQuality.standard,
    ),
  );
}

/// 用户可调的玻璃参数（应用外观 → 液体玻璃：模糊强度 / 厚度）。
///
/// [kAppGlassSurfaceSettings] 是 const，显式把它传进 `settings:` 的地方
/// （底栏、迷你播放器）会**盖掉** [appGlassTheme] 里已经接好的滑块值 ——
/// 表现就是「模糊和厚度调了跟没调一样」，因为用户盯着看的恰好就是这两块。
/// 需要显式传参的地方一律改用这个函数，并记得挂 [appGlassTunables] 重建。
LiquidGlassSettings appGlassSurfaceSettings({Color? glassColor}) {
  final base = kAppGlassSurfaceSettings.copyWith(
    blur: AppGlassSettings.glassBlurStrength.value,
    thickness: AppGlassSettings.glassThickness.value,
  );
  // 不把 null 传进 copyWith：包的 copyWith 对 null 是「保留」还是「清空」
  // 无从验证（本机没有 pub 缓存），传空等于赌它的实现。有值才覆盖。
  return glassColor == null ? base : base.copyWith(glassColor: glassColor);
}

/// 玻璃滑块的可监听体：用 [appGlassSurfaceSettings] 的地方套一层
/// `ListenableBuilder`，否则拖完滑块要切页才看得到变化。
Listenable get appGlassTunables => Listenable.merge([
  AppGlassSettings.glassBlurStrength,
  AppGlassSettings.glassThickness,
]);

/// 玻璃底板色：玻璃本身在浅色壁纸上几乎没有边界，垫一层半透明底板给它轮廓。
///
/// 底栏和迷你播放器**共用**这一组值 —— 之前底栏有底板、迷你播放器没有，
/// 一个是亮底板一个是近乎全透的玻璃，摆在一起就是「两块不是一套的东西」。
Color appGlassPlateColor(bool isDark) => isDark
    ? Colors.black.withValues(alpha: 0.42)
    : Colors.white.withValues(alpha: 0.74);

/// 玻璃底板的发丝描边（未自定义边框颜色时的默认值）。
Color appGlassPlateBorderColor(bool isDark) => isDark
    ? Colors.white.withValues(alpha: 0.30)
    : Colors.black.withValues(alpha: 0.20);
