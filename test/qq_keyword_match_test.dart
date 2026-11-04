import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/qq/qq_models.dart';
import 'package:feiniu_music/app/services/unblock/unblock_source.dart';

/// QQ 按歌名兜底的挑歌规则。搜索结果是 2026-11-05 实际搜到的前 5 条。
void main() {
  QQSong song(String name, String artists, int seconds, String mid) => QQSong(
    mid: mid,
    songId: 0,
    name: name,
    artists: artists,
    album: '',
    albumMid: null,
    mediaMid: null,
    durationMs: seconds * 1000,
    payPlay: false,
  );

  test('时长一样但歌名不对的不要（粤语版《也无风雨也无月》）', () {
    final results = [
      song('也无风雨也无月 (粤语)', '林峯', 267, 'A'),
      song('不负如来不负卿 (国语)', '林峯', 267, 'B'),
      song('不负如来不负卿', '林峯', 267, 'C'),
    ];
    final m = UnblockSourceService.pickQQMatch(results, '不负如来不负卿 林峯', 267000);
    expect(m?.mid, 'B');
  });

  test('Live 版时长对不上，跳过，挑原版', () {
    final results = [
      song('晴天 (Live)', '周杰伦', 249, 'L'),
      song('晴天', '周杰伦', 269, 'O'),
    ];
    final m = UnblockSourceService.pickQQMatch(results, '晴天 周杰伦', 269000);
    expect(m?.mid, 'O');
  });

  test('全都对不上就放弃', () {
    final results = [
      song('其实', '薛之谦', 242, 'X'),
      song('天外来物 (Live)', '薛之谦', 201, 'Y'),
    ];
    expect(
      UnblockSourceService.pickQQMatch(results, '天外来物 薛之谦', 257000),
      isNull,
    );
  });

  test('没有时长时只看歌名', () {
    final results = [song('花海', '周杰伦', 264, 'H'), song('晴天', '周杰伦', 269, 'O')];
    expect(UnblockSourceService.pickQQMatch(results, '晴天 周杰伦', 0)?.mid, 'O');
  });
}
