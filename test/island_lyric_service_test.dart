import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/island_lyric_service.dart';

void main() {
  group('IslandLyricService.shouldShow', () {
    test('开关关闭时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: false,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('未在播放时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: false,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('无歌词行时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: null,
        ),
        false,
      );
    });

    test('播放中且有歌词时显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        true,
      );
    });
  });

  group('IslandLyricService.shouldUpdate', () {
    test('首行歌词（上一行为空）更新', () {
      expect(
        IslandLyricService.shouldUpdate(previous: null, next: '第一行'),
        true,
      );
    });

    test('歌词行变化时更新', () {
      expect(
        IslandLyricService.shouldUpdate(previous: '第一行', next: '第二行'),
        true,
      );
    });

    test('歌词行未变化时不更新（去重）', () {
      expect(
        IslandLyricService.shouldUpdate(previous: '同一行', next: '同一行'),
        false,
      );
    });
  });

  group('IslandLyricService.simulateTestPayload', () {
    test('测试模式 payload：歌词循环 + 进度递增（0→100 后归零循环）', () {
      final p0 = IslandLyricService.simulateTestPayload(tick: 0, lyricCount: 4);
      // payload 里 lyric 是右半、leftLyric 是左半；空格作为分割点被丢弃，
      // 两侧各自干净显示（左=短语、右=序号）
      expect(p0['leftLyric'], '测试歌词');
      expect(p0['lyric'], '1/4');
      expect(p0['progress'], 0);

      final p3 = IslandLyricService.simulateTestPayload(tick: 3, lyricCount: 4);
      expect(p3['leftLyric'], '测试歌词');
      expect(p3['lyric'], '4/4');
      expect(p3['progress'], 75);

      // 循环：tick=4 回到第一行，进度归零
      final p4 = IslandLyricService.simulateTestPayload(tick: 4, lyricCount: 4);
      expect(p4['leftLyric'], '测试歌词');
      expect(p4['lyric'], '1/4');
      expect(p4['progress'], 0);
    });

    test('测试模式 payload 始终 isPlaying=true（模拟播放中）', () {
      final p = IslandLyricService.simulateTestPayload(tick: 1, lyricCount: 2);
      expect(p['isPlaying'], true);
      expect(p['title'], '灵动岛测试');
    });
  });

  group('IslandLyricService.splitLyricForIsland', () {
    test('短歌词也左右拼接：两侧非空且拼成完整歌词', () {
      const lyric = '短歌词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '短歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '短歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '左右拼接等于完整歌词');
    });

    test('短歌词均分：两侧字符数差不超过 1', () {
      const lyric = '短歌词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect((r.left.length - r.right.length).abs(), lessThanOrEqualTo(1),
          reason: '短歌词应按字符均分，两侧接近等长');
    });

    test('2字帧：左右各 1 字（不整段只放一侧）', () {
      const lyric = 'XX';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, 'X', reason: '2字帧左侧应恰好 1 字');
      expect(r.right, 'X', reason: '2字帧右侧应恰好 1 字');
    });

    test('空格分隔的短语：在空格处断，两侧不带头尾空格', () {
      const lyric = '聆听山语 回荡不清';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, '聆听山语', reason: '左半应在空格处断，不带空格');
      expect(r.right, '回荡不清', reason: '右半应在空格处断，不带空格');
      expect(r.left.trim(), r.left, reason: '左侧不带头尾空格');
      expect(r.right.trim(), r.right, reason: '右侧不带头尾空格');
    });

    test('奇数帧：右侧多 1 字（ceil 均分）', () {
      const lyric = '三字词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left.runes.length, 2, reason: '3字帧左侧 2 字');
      expect(r.right.runes.length, 1, reason: '3字帧右侧 1 字');
      expect('${r.left}${r.right}', lyric);
    });

    test('长歌词：按长度对半分割，左右衔接拼成完整歌词', () {
      const lyric = '这是一段比较长的歌词用来测试左右分割衔接的效果';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty);
      expect(r.right, isNotEmpty);
      // 左右拼接起来应等于完整歌词（衔接）
      expect('${r.left}${r.right}', lyric);
    });

    test('空歌词：两侧皆空', () {
      final r = IslandLyricService.splitLyricForIsland('');
      expect(r.left, isEmpty);
      expect(r.right, isEmpty);
    });

    test('超长歌词：同样左右拼接，两侧同时非空', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '超长歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '超长歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '超长歌词也应左右拼接成完整歌词');
    });
  });

  group('IslandLyricService.shouldSendCover', () {
    test('同一首歌同一封面：不需要重发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c1',
        ),
        false,
      );
    });

    test('切歌到新封面：需要发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's2',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('同一首歌封面变化（updatedAt 刷新）：需要发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('无封面 id：不发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: null,
          newSongId: 's2',
          newCoverId: null,
        ),
        false,
      );
    });
  });

  group('IslandLyricService.chunkLyric', () {
    test('短歌词（≤10字）：单帧（整行）', () {
      const lyric = '短歌词';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('超长歌词：拆成多帧，每帧不超过 frameChars', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1));
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '每帧应不超过单帧容量');
      }
      // 所有帧拼接 = 完整歌词（无丢失）
      expect(frames.join(), lyric);
    });

    test('智能截断：优先在空格词边界断，短词不被切散', () {
      // 空格分隔的短词（≤10字）应保持完整，不被切散
      const lyric = '今天天气很好 我们去爬山 明天再出发';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      // 每个空格分隔的词都完整出现在某一帧里（不被切散）
      expect(frames.join(' ').contains('今天天气很好'), isTrue);
      expect(frames.join(' ').contains('我们去爬山'), isTrue);
      expect(frames.join(' ').contains('明天再出发'), isTrue);
      // 帧内不含空格（空格作为断点被消费，不留在帧首尾）
      for (final frame in frames) {
        expect(frame.contains(' '), isFalse, reason: '帧内不应含空格');
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
    });

    test('智能截断：超长 ASCII 单词本身必须被切（无法整词保留）', () {
      const lyric = 'Supercalifragilistic';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1), reason: '超长单词应被切成多帧');
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '即使切单词，每帧也不超过 10 字');
      }
      expect(frames.join(), lyric, reason: '拼接等于完整单词');
    });

    test('恰好 10 字：单帧', () {
      const lyric = '一二三四五六七八九十';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('拆帧不含尾随空格（避免空格留在帧尾导致滚动）', () {
      const lyric = '聆听山语 回荡不清 若即若离';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      for (final frame in frames) {
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
      // 去掉空格后拼接仍等于原词（空格作为分隔符丢弃）
      final joined = frames.map((f) => f.trim()).join();
      expect(joined.replaceAll(' ', ''), '聆听山语回荡不清若即若离');
    });

    test('空歌词：无帧', () {
      final frames = IslandLyricService.chunkLyric('', frameChars: 10);
      expect(frames, isEmpty);
    });
  });

  group('IslandLyricService.frameIndexForPosition', () {
    // 行时间窗口 [2000ms, 4000ms]，两帧：帧0=[2000,3000)，帧1=[3000,4000)
    test('位置在行开始前：第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 1000,
        ),
        0,
      );
    });

    test('位置在前半段（中点前）：第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 2500,
        ),
        0,
      );
    });

    test('位置在后半段（中点后）：第 1 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        1,
      );
    });

    test('位置在行结束后：最后一帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 99999,
        ),
        1,
      );
    });

    test('单帧或无 end：恒第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 1,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        0,
      );
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: null,
          positionMs: 3500,
        ),
        0,
      );
    });
  });
}
