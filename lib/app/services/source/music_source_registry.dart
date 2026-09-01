import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player_service.dart';
import 'feiniu_source.dart';
import 'music_source.dart';
import 'netease_source.dart';

/// 当前音乐数据源。
///
/// 首页从这里取源，切换后重新加载。**不参与登录门控** —— 飞牛账号仍是 App
/// 的入口，网易云是叠加上去的第二个源，不是替代品。上一版把源切换做进门控，
/// 结果冷启动和退出都别扭。
class MusicSourceRegistry {
  MusicSourceRegistry._();

  static final MusicSourceRegistry instance = MusicSourceRegistry._();

  static const String _prefsKey = 'setting_active_music_source';

  /// 所有可选源。顺序即「我的」页面里的展示顺序。
  static final List<MusicSource> all = [
    FeiniuSource.instance,
    NetEaseSource.instance,
  ];

  final ValueNotifier<MusicSource> current = ValueNotifier(
    FeiniuSource.instance,
  );

  /// 当前源的**内容**发生变化（登录 / 登出）时自增。
  ///
  /// 光监听 [current] 不够：源没换、但登录了，首页照样得重新拉一次 ——
  /// 否则登录完回到首页，收藏和最近播放还是登录前那份空数据。
  final ValueNotifier<int> revision = ValueNotifier(0);

  void notifyContentChanged() => revision.value++;

  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved == null) return;
      current.value = all.firstWhere(
        (s) => s.id == saved,
        orElse: () => FeiniuSource.instance,
      );
    } catch (_) {
      // 读不出来就用飞牛，别卡住启动。
    } finally {
      _syncPlayerRoamSupport();
    }
  }

  /// 把「当前源有没有漫游链」同步给播放器。
  ///
  /// roam-start / roam-next 是飞牛独有的。不同步的话，换到网易云之后播到
  /// 队尾播放器还会去起飞牛的漫游链，把正在放的歌整个换掉。放在这里而不是
  /// 首页，是因为首页可能已经被销毁，而播放器一直活着。
  void _syncPlayerRoamSupport() {
    PlayerService.instance.roamChainSupported = current.value.id == 'feiniu';
  }

  Future<void> setCurrent(MusicSource source) async {
    if (identical(current.value, source)) return;
    current.value = source;
    _syncPlayerRoamSupport();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, source.id);
    } catch (_) {}
  }

  MusicSource byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => FeiniuSource.instance);
}
