import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lxscript/lx_source_manager.dart';

/// 有的 LX 脚本拿不到地址时不报错，而是塞一段固定的几秒音频（ikun 的酷狗
/// 就是 gitcode 上同一个 7 秒 mp3），App 以为命中了，播 7 秒就切歌。
void main() {
  final m = LxSourceManager.instance;

  test('已知的占位地址直接拦掉', () {
    expect(
      m.isPlaceholder(
        'https://cdn-img.gitcode.com/db/ee/d36b.mp3?response-content-type=audio/mpeg',
        'kg/AAA',
      ),
      isTrue,
    );
  });

  test('同一个地址给了两首不同的歌 → 第二次起判为占位', () {
    const url = 'https://example.com/fake.mp3?t=1';
    expect(m.isPlaceholder(url, 'kg/111'), isFalse);
    // 同一首歌再要一次地址是正常的
    expect(
      m.isPlaceholder('https://example.com/fake.mp3?t=2', 'kg/111'),
      isFalse,
    );
    expect(m.isPlaceholder(url, 'kg/222'), isTrue);
    // 记住了，之后连原来那首也不再信它
    expect(m.isPlaceholder(url, 'kg/111'), isTrue);
  });

  test('每首歌各自的真直链不受影响', () {
    expect(
      m.isPlaceholder('https://fs.kugou.com/a/111.mp3', 'kg/111'),
      isFalse,
    );
    expect(
      m.isPlaceholder('https://fs.kugou.com/a/222.mp3', 'kg/222'),
      isFalse,
    );
  });
}
