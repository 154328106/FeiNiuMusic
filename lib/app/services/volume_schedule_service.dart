import 'dart:async';

import '../state/settings_state.dart';

/// 定时音量调度器：在设定的时间段内把音量强制到段内设定值，
/// 离开时间段后恢复手动音量（`AppPlaybackVolumeSettings.volume` 的当前值）。
///
/// 只通过 `AppPlaybackVolumeSettings.setVolume` 写音量——volume notifier 的
/// 监听（`PlayerService._handleAppVolumeChanged`）会自动把值流到播放器。
class VolumeScheduleService {
  static final VolumeScheduleService instance = VolumeScheduleService._();

  VolumeScheduleService._() {
    AppVolumeScheduleSettings.enabled.addListener(_onSettingsChanged);
    AppVolumeScheduleSettings.periods.addListener(_onSettingsChanged);
  }

  Timer? _ticker;
  VolumeSchedulePeriod? _active;
  bool _started = false;

  bool get isActive => _active != null;

  /// 幂等启动：App 启动时调用一次。加载设置、立即应用一次、启动 1s 心跳。
  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    await AppVolumeScheduleSettings.ensureLoaded();
    await _applySchedule();
    _restartTickerIfNeeded();
  }

  /// 立即重检一次（生命周期 resume、手动音量变化、tick）。
  void checkNow() {
    unawaited(_applySchedule());
  }

  /// 关闭心跳并释放监听（仅在测试/热重载时触发；App 进程生命周期内不调用）。
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    AppVolumeScheduleSettings.enabled.removeListener(_onSettingsChanged);
    AppVolumeScheduleSettings.periods.removeListener(_onSettingsChanged);
  }

  // ---------- 调度逻辑 ----------

  Future<void> _applySchedule() async {
    if (!AppVolumeScheduleSettings.enabled.value) {
      if (_active != null) {
        // 开关被关闭且当前在生效时间段 → 恢复手动音量。
        _active = null;
        AppVolumeScheduleSettings.isActiveNow.value = false;
        await AppPlaybackVolumeSettings.setVolume(
          AppVolumeScheduleSettings.manualVolume.value,
        );
      }
      _restartTickerIfNeeded();
      return;
    }

    final p = AppVolumeScheduleSettings.activePeriodNow(DateTime.now());
    if (p != null) {
      if (p.id != _active?.id) {
        // 进入新时间段 → 快照手动音量并强制段内音量。
        AppVolumeScheduleSettings.manualVolume.value =
            AppPlaybackVolumeSettings.volume.value;
        _active = p;
        AppVolumeScheduleSettings.isActiveNow.value = true;
        await AppPlaybackVolumeSettings.setVolume(p.volume);
      } else if ((AppPlaybackVolumeSettings.volume.value - p.volume).abs() >
          0.001) {
        // 仍在同一时间段但音量被手动改过 → 重新强制段内音量。
        // （volume notifier 的监听会让 _applySchedule 立刻跑一次，这里是 tick 兜底）
        await AppPlaybackVolumeSettings.setVolume(p.volume);
      }
    } else if (_active != null) {
      // 离开时间段 → 恢复手动音量。
      _active = null;
      AppVolumeScheduleSettings.isActiveNow.value = false;
      await AppPlaybackVolumeSettings.setVolume(
        AppVolumeScheduleSettings.manualVolume.value,
      );
    } else {
      AppVolumeScheduleSettings.isActiveNow.value = false;
    }
    _restartTickerIfNeeded();
  }

  void _onSettingsChanged() {
    unawaited(_applySchedule());
  }

  // ---------- 心跳 ----------

  /// 仅在开关开启或存在生效时间段时运行 1s 心跳，否则取消以省电。
  void _restartTickerIfNeeded() {
    final shouldRun = AppVolumeScheduleSettings.enabled.value || _active != null;
    if (shouldRun) {
      if (_ticker != null) return;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => checkNow());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }
}
