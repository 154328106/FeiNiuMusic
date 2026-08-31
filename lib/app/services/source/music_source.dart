import 'package:flutter/material.dart';

import '../../state/song_state.dart';

/// 首页那几条歌曲流。
///
/// 与首页区块一一对应，也决定点播放时按队列上限去拉哪份完整列表。
enum HomeFeed {
  /// 收藏 / 我喜欢的音乐。
  favorites,

  /// 最近播放。
  recentPlayed,

  /// 最新歌曲 / 推荐新歌。
  latestSongs,
}

/// 中性的歌单条目。
///
/// 飞牛的 `FeiNiuPlaylist` 带 guid 等自家概念，直接用它做首页模型就把 UI
/// 焊死在飞牛上了。这里只保留两边都有的字段。
class SourcePlaylist {
  const SourcePlaylist({
    required this.id,
    required this.name,
    required this.coverId,
    this.trackCount = 0,
  });

  /// 带源前缀的 id，约定与 `SongEntity.id` 一致（见 `SongSource`）。
  final String id;
  final String name;

  /// 封面标识。飞牛是 coverId，网易云是完整 http 地址 —— 与
  /// `SongEntity.coverId` 同一个约定，渲染层按 `http` 开头分流。
  final String? coverId;

  final int trackCount;
}

/// 首页顶部大图的数据。
class SourceHero {
  const SourceHero({
    required this.song,
    required this.queue,
    required this.label,
    this.chainId,
  });

  final SongEntity song;

  /// 点播放时直接用的队列（至少含 [song] 本身）。
  final List<SongEntity> queue;

  /// 大图左上角的标签，如「漫游 · 随心听」「每日推荐」。
  final String label;

  /// 飞牛漫游的 roamId；其它源没有这个概念，为 null。
  final String? chainId;
}

/// 一个音乐数据源。
///
/// 首页只跟这个接口打交道，不再直接调飞牛的 API —— 这样换源时 UI 一行不用动。
abstract class MusicSource {
  /// 稳定标识，用于持久化「当前源」。
  String get id;

  String get label;
  IconData get icon;
  Color get accent;

  /// 是否可用（已登录 / 已配置）。不可用时首页显示 [unavailableHint]。
  bool get isAvailable;

  /// 不可用的原因，以及该怎么办。
  String get unavailableHint;

  /// 顶部大图。拿不到返回 null（首页会隐藏该区块）。
  Future<SourceHero?> hero();

  /// 换一首大图（飞牛走 roam-next；其它源重新取推荐）。
  Future<SourceHero?> refreshHero();

  /// 首页某条流的**预览**（首页只展示前几首）。
  Future<List<SongEntity>> feed(HomeFeed kind, {int limit = 10});

  /// 某条流的**完整列表**，点播放时按队列上限拉取。
  Future<List<SongEntity>> fullFeed(HomeFeed kind, {required int limit});

  /// 歌单列表。
  Future<List<SourcePlaylist>> playlists({int limit = 10});

  /// 歌单内的歌曲。
  Future<List<SongEntity>> playlistSongs(String playlistId);
}
