import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/source/artist_cover_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('慢的不卡住列表：最多等 wait，没搜到的后台接着搜', () async {
    var calls = 0;
    final cache = ArtistCoverCache('test.covers', (name) async {
      calls++;
      // 「慢歌手」要 300ms，超过 wait
      await Future<void>.delayed(
        Duration(milliseconds: name == '慢歌手' ? 300 : 10),
      );
      return 'http://img/$name.jpg';
    }, wait: const Duration(milliseconds: 100));
    final sw = Stopwatch()..start();
    final first = await cache.covers(['快歌手', '慢歌手']);
    expect(sw.elapsedMilliseconds, lessThan(250));
    // 同一批里并发跑，慢的那个还没回来，所以这一批都还没写进来
    expect(first.containsKey('慢歌手'), isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    final second = await cache.covers(['快歌手', '慢歌手']);
    expect(second['慢歌手'], 'http://img/慢歌手.jpg');
    expect(calls, 2); // 第二次没再请求
  });

  test('存到本地：换一个实例（重启 App）直接用，不再请求', () async {
    final a = ArtistCoverCache(
      'test.covers2',
      (n) async => 'http://img/$n.jpg',
    );
    await a.covers(['周杰伦', '林俊杰']);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    var calls = 0;
    final b = ArtistCoverCache('test.covers2', (n) async {
      calls++;
      return 'x';
    });
    final got = await b.covers(['周杰伦', '林俊杰']);
    expect(got['周杰伦'], 'http://img/周杰伦.jpg');
    expect(calls, 0);
  });

  test('搜不到 / 出错的不存，下次再试', () async {
    var calls = 0;
    final c = ArtistCoverCache('test.covers3', (n) async {
      calls++;
      if (n == '坏') throw Exception('网络错');
      return null;
    });
    final got = await c.covers(['坏', '空']);
    expect(got, isEmpty);
    await c.covers(['坏', '空']);
    expect(calls, 4);
  });
}
