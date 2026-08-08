import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/plugin/plugin_result_parser.dart';
import 'package:feiniu_music/app/services/song_match/song_match_scorer.dart';

SongMatchResult _r({
  required String id,
  required String pluginId,
  required String title,
  String artist = '',
  String album = '',
}) {
  return SongMatchResult(id: id, pluginId: pluginId, pluginName: pluginId, title: title, artist: artist, album: album);
}

void main() {
  group('SongMatchScorer.score', () {
    test('完全匹配最高分', () {
      expect(SongMatchScorer.score(_r(id: '1', pluginId: 'a', title: '我等你'), '我等你'), 100);
    });

    test('标题包含关键词次之', () {
      final s = SongMatchScorer.score(_r(id: '1', pluginId: 'a', title: '我等你 (Live)'), '我等你');
      expect(s, 80);
    });

    test('歌手/专辑命中加分', () {
      final s = SongMatchScorer.score(
        _r(id: '1', pluginId: 'a', title: '我等你', artist: '刘若英'),
        '我等你',
      );
      expect(s, 100); // 完全匹配标题已 100，歌手命中不再额外加分
      final partial = SongMatchScorer.score(
        _r(id: '2', pluginId: 'a', title: '不同的歌', artist: '我等你乐队'),
        '我等你',
      );
      expect(partial, 10, reason: '标题无关仅歌手命中 → 10');
      final noMatch = SongMatchScorer.score(
        _r(id: '3', pluginId: 'a', title: '完全无关的歌', artist: '某人'),
        '我等你',
      );
      expect(noMatch, 0);
    });
  });

  group('SongMatchScorer.mergeRanked', () {
    test('匹配度降序排列', () {
      final groups = [
        [
          _r(id: '1', pluginId: 'qq', title: '我等你 (Live)'),
          _r(id: '2', pluginId: 'qq', title: '完全无关的歌'),
        ],
        [
          _r(id: '3', pluginId: 'netease', title: '我等你'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(groups, '我等你');
      expect(merged.first.id, '3', reason: '完全匹配应排第一');
      expect(merged[1].id, '1', reason: '包含关键词次之');
      expect(merged.last.id, '2');
    });

    test('同分按源顺序靠前优先', () {
      final groups = [
        [
          _r(id: 'netease-1', pluginId: 'netease', title: '我等你'),
          _r(id: 'qq-1', pluginId: 'qq', title: '我等你'),
        ],
      ];
      // netease 在 qq 前 → 同分时 netease 靠前
      final merged = SongMatchScorer.mergeRanked(
        groups,
        '我等你',
        sourceOrder: ['netease', 'qq'],
      );
      expect(merged.first.id, 'netease-1');
      expect(merged.last.id, 'qq-1');
    });

    test('源顺序反转则优先级反转', () {
      final groups = [
        [
          _r(id: 'netease-1', pluginId: 'netease', title: '我等你'),
          _r(id: 'qq-1', pluginId: 'qq', title: '我等你'),
        ],
      ];
      final merged = SongMatchScorer.mergeRanked(
        groups,
        '我等你',
        sourceOrder: ['qq', 'netease'],
      );
      expect(merged.first.id, 'qq-1');
    });
  });
}
