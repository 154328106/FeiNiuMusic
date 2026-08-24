import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/media_kit_engine.dart';
import 'package:feiniu_music/app/services/player/player_engine.dart';

void main() {
  group('mediaKitProcessingState', () {
    test('中间歌曲 EOF 不上报整个播放列表完成', () {
      expect(
        mediaKitProcessingState(
          buffering: false,
          completed: true,
          playlistIndex: 1,
          playlistLength: 3,
        ),
        EngineProcessingState.ready,
      );
    });

    test('最后一首 EOF 上报播放列表完成', () {
      expect(
        mediaKitProcessingState(
          buffering: false,
          completed: true,
          playlistIndex: 2,
          playlistLength: 3,
        ),
        EngineProcessingState.completed,
      );
    });

    test('缓冲状态优先于完成状态', () {
      expect(
        mediaKitProcessingState(
          buffering: true,
          completed: true,
          playlistIndex: 2,
          playlistLength: 3,
        ),
        EngineProcessingState.buffering,
      );
    });
  });
}
