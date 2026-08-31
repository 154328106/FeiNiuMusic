import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/player_engine.dart';
import 'package:feiniu_music/app/services/player/playback_router.dart';
import 'package:feiniu_music/app/state/settings_transcode_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 构造带 format/codec 的歌曲（两者都显式给值 → routeForSong 零网络开销）。
SongEntity _song(String id, {String? format, String? codec}) {
  return SongEntity(
    id: id,
    title: 't',
    artist: '[{"name":"a"}]',
    format: format,
    codec: codec,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 「优先 FFmpeg 解码」默认开启，开着的话一切格式都返回 mediaKit，
  // 下面这组用例考的是**格式/codec → 引擎**的映射，必须先关掉全局覆盖
  // 才测得到那条路径。
  setUp(() => AppTranscodeSettings.preferFfmpegDecoder.value = false);
  tearDown(() => AppTranscodeSettings.preferFfmpegDecoder.value = true);

  group('优先 FFmpeg 解码（全局覆盖）', () {
    test('开启后普通格式也走 mediaKit', () {
      AppTranscodeSettings.preferFfmpegDecoder.value = true;
      expect(routeForFormat('mp3', codec: 'mp3'), EngineKind.mediaKit);
      expect(routeForFormat('flac', codec: 'flac'), EngineKind.mediaKit);
      expect(routeForFormat(null), EngineKind.mediaKit);
    });

    test('关闭后回到按格式路由', () {
      AppTranscodeSettings.preferFfmpegDecoder.value = false;
      expect(routeForFormat('mp3', codec: 'mp3'), EngineKind.justAudio);
      // 黑名单格式仍然走 mediaKit，与全局开关无关。
      expect(routeForFormat('dsf'), EngineKind.mediaKit);
    });
  });

  group('routeForFormat（codec 感知）', () {
    test('M4A + EAC3 → mediaKit（本次无声 bug 场景）', () {
      expect(
        routeForFormat('m4a', codec: 'eac3'),
        EngineKind.mediaKit,
        reason: 'EAC3 的 M4A 应交给 media_kit（FFmpeg）必出声',
      );
    });

    test('M4A + ALAC → mediaKit', () {
      expect(
        routeForFormat('m4a', codec: 'alac'),
        EngineKind.mediaKit,
      );
    });

    test('M4A + AAC → justAudio（系统解码，不变）', () {
      expect(
        routeForFormat('m4a', codec: 'aac'),
        EngineKind.justAudio,
      );
    });

    test('M4A + codec 未知 → justAudio（保持现状，交给无声看门狗兜底）', () {
      expect(
        routeForFormat('m4a'),
        EngineKind.justAudio,
      );
      expect(
        routeForFormat('m4a', codec: null),
        EngineKind.justAudio,
      );
    });

    test('format 黑名单仍生效：dsf 即使 codec=aac 也走 mediaKit', () {
      expect(
        routeForFormat('dsf', codec: 'aac'),
        EngineKind.mediaKit,
      );
    });

    test('codec 大小写不敏感', () {
      expect(routeForFormat('m4a', codec: 'EAC3'), EngineKind.mediaKit);
      expect(routeForFormat('m4a', codec: 'Ac3'), EngineKind.mediaKit);
    });

    test('普通格式（flac/mp3/ogg）+ 普通 codec → justAudio', () {
      expect(routeForFormat('flac', codec: 'flac'), EngineKind.justAudio);
      expect(routeForFormat('mp3', codec: 'mp3'), EngineKind.justAudio);
      expect(routeForFormat('ogg', codec: 'vorbis'), EngineKind.justAudio);
    });

    test('null/空 format + 普通 codec → justAudio', () {
      expect(routeForFormat(null, codec: 'aac'), EngineKind.justAudio);
      expect(routeForFormat('', codec: 'aac'), EngineKind.justAudio);
    });
  });

  group('routeForSong', () {
    test('M4A + EAC3 歌曲 → mediaKit（零网络）', () async {
      final kind = await routeForSong(_song('r1', format: 'm4a', codec: 'eac3'));
      expect(kind, EngineKind.mediaKit);
    });

    test('M4A + AAC 歌曲 → justAudio（零网络）', () async {
      final kind = await routeForSong(_song('r2', format: 'm4a', codec: 'aac'));
      expect(kind, EngineKind.justAudio);
    });
  });
}
