import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../components/index.dart';

/// 转码设置页：开启转码 / 全部转码 / 转码文件大小 / 转码格式。
class TranscodeSettingsPage extends StatefulWidget {
  const TranscodeSettingsPage({super.key});

  @override
  State<TranscodeSettingsPage> createState() => _TranscodeSettingsPageState();
}

class _TranscodeSettingsPageState extends State<TranscodeSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppTranscodeSettings.ensureLoaded();
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
        title: '转码设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '转码',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppTranscodeSettings.enabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '开启转码',
                    subtitle: '关闭时全部直接播放（不转码）；开启后大文件/无损文件先经服务器转码再播放',
                    value: enabled,
                    onChanged: AppTranscodeSettings.setEnabled,
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppTranscodeSettings.transcodeAll,
                builder: (context, transcodeAll, _) {
                  return AppSettingSwitchTile(
                    title: '全部转码',
                    subtitle: '开启 = 所有文件都转码（含 DSF/APE/WMA 等无损，忽略大小阈值）；关闭 = 仅超过下方阈值的文件转码',
                    value: transcodeAll,
                    onChanged: AppTranscodeSettings.setTranscodeAll,
                  );
                },
              ),
              ValueListenableBuilder<int>(
                valueListenable: AppTranscodeSettings.thresholdMb,
                builder: (context, thresholdMb, _) {
                  return AppSettingSlider(
                    title: '转码文件大小',
                    description:
                        '仅「全部转码」关闭时生效：超过该大小的文件转码；未识别大小的文件不转码',
                    value: thresholdMb.toDouble(),
                    min: AppTranscodeSettings.minThresholdMb.toDouble(),
                    max: AppTranscodeSettings.maxThresholdMb.toDouble(),
                    divisions: (AppTranscodeSettings.maxThresholdMb -
                            AppTranscodeSettings.minThresholdMb) ~/
                        10,
                    valueText: '$thresholdMb MB',
                    onChanged: (value) {
                      AppTranscodeSettings.setThresholdMb(value.round());
                    },
                  );
                },
              ),
              ValueListenableBuilder<TranscodeFormat>(
                valueListenable: AppTranscodeSettings.format,
                builder: (context, format, _) {
                  return _buildFormatTile(context, format);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormatTile(BuildContext context, TranscodeFormat format) {
    const labels = {
      TranscodeFormat.flac: 'FLAC 无损',
      TranscodeFormat.mp3: 'MP3',
      TranscodeFormat.opus: 'OPUS',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '转码格式',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<TranscodeFormat>(
              segments: [
                for (final f in TranscodeFormat.values)
                  ButtonSegment(
                    value: f,
                    label: Text(labels[f] ?? f.name),
                  ),
              ],
              selected: {format},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                AppTranscodeSettings.setFormat(selection.first);
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'FLAC 为无损；MP3/OPUS 为有损',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
