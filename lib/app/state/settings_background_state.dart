import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppBackgroundSettings {
  static const String _prefsBackgroundImagePath =
      'setting_background_image_path';
  static const String _prefsBackgroundMaskOpacity =
      'setting_background_mask_opacity';
  static const String _prefsBackgroundBlurSigma =
      'setting_background_blur_sigma';
  static const String _prefsPageGlowEnabled = 'setting_page_glow_enabled';
  static const String _prefsPanelOpacity = 'setting_panel_opacity';

  static final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);
  static final ValueNotifier<double> backgroundMaskOpacity = ValueNotifier(
    0.35,
  );
  // 0 = original sharp image, 32 = heavily blurred. Users kept complaining
  // that "透明度=0" still looked hazy — that was this constant-16 blur.
  static final ValueNotifier<double> backgroundBlurSigma = ValueNotifier(16);
  static final ValueNotifier<bool> pageGlowEnabled = ValueNotifier(false);
  static final ValueNotifier<double> panelOpacity = ValueNotifier(0.72);

  // Legacy notifiers — the "毛玻璃质感" feature was removed. They are kept so
  // widgets that still read them compile without a rewrite, but their values
  // are pinned to "off" and no UI can flip them back on.
  static final ValueNotifier<bool> glassEffectEnabled = ValueNotifier(false);
  static final ValueNotifier<double> panelBlurStrength = ValueNotifier(0);

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
    panelOpacity.value = (prefs.getDouble(_prefsPanelOpacity) ?? 0.72).clamp(
      0.0,
      1.0,
    );
    // Legacy — always report "glass off" regardless of what's on disk.
    glassEffectEnabled.value = false;
    panelBlurStrength.value = 0;
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

  static Future<void> setPanelOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 1.0);
    await prefs.setDouble(_prefsPanelOpacity, next);
    panelOpacity.value = next;
  }
}
