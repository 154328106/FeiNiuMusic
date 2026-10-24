import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../components/index.dart';
import '../player/widgets/player_background.dart';

class GradientSettingsPage extends StatefulWidget {
  const GradientSettingsPage({super.key});

  @override
  State<GradientSettingsPage> createState() => _GradientSettingsPageState();
}

class _GradientSettingsPageState extends State<GradientSettingsPage>
    with SignalsMixin {
  late final _saturation = createSignal(1.2);
  late final _hueShift = createSignal(0.0);
  // 一次性加载态用 State 字段（setState），避免整页 Watch.builder
  // 在滑块拖动时连带重建预览与脚手架。
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await PlayerBackgroundSettings.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _saturation.value = PlayerBackgroundSettings.saturation.value;
      _hueShift.value = PlayerBackgroundSettings.hueShift.value;
      _loading = false;
    });
  }

  void _updateSaturation(double value) {
    _saturation.value = value;
    PlayerBackgroundSettings.setSaturation(value);
  }

  void _updateHueShift(double value) {
    _hueShift.value = value;
    PlayerBackgroundSettings.setHueShift(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '流光设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const _GradientPreview(),
          const SizedBox(height: 16),
          // 仅滑块区块订阅 _saturation/_hueShift：拖动时只重建这一小块，
          // 不重建上方动态预览与脚手架（预览内部会因 setSaturation 自动更新）。
          Watch.builder(
            builder: (context) => AppSettingSection(
              title: '参数配置',
              children: [
                AppSettingSlider(
                  title: '色彩饱和度',
                  value: _saturation.value,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  valueText: '${(_saturation.value * 100).toInt()}%',
                  description: '数值越大越鲜艳，越小越灰淡',
                  onChanged: _updateSaturation,
                ),
                AppSettingSlider(
                  title: '色彩变幻度',
                  value: _hueShift.value,
                  min: 0.0,
                  max: 180.0,
                  divisions: 18,
                  valueText: '${_hueShift.value.toInt()}°',
                  description: '数值越大变化更强，越小更稳定',
                  onChanged: _updateHueShift,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 左：播放页，右：歌词页 —— 用的是真机截图（assets/preview/gradient_preview_*），
/// 一眼看出流光开出来是什么样。
class _GradientPreview extends StatelessWidget {
  const _GradientPreview();

  // 截图裁掉状态栏后是 1290 × 2646。
  static const _ratio = 1290 / 2646;

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _PreviewScreen(
            label: '播放器',
            asset: 'assets/preview/gradient_preview_player.jpg',
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _PreviewScreen(
            label: '歌词页',
            asset: 'assets/preview/gradient_preview_lyrics.jpg',
          ),
        ),
      ],
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  final String label;
  final String asset;

  const _PreviewScreen({required this.label, required this.asset});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: _GradientPreview._ratio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(asset, fit: BoxFit.cover),
            Positioned(
              left: 10,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
