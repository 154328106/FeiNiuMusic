import 'package:flutter_test/flutter_test.dart';
import 'package:nagomusic/app/services/lyrics/lyrics_parser.dart';

void main() {
  test('parse translation line with same timestamp', () {
    const lrc = '''
[00:02.392]Ave [00:02.574]Maria [00:04.301]grazia [00:04.589]ricevuta [00:06.145]per [00:06.318]la [00:06.535]mia [00:06.710]famiglia[00:07.285]
[00:02.392]\u4e07\u798f\u739b\u5229\u4e9a \u611f\u8c22\u60a8\u5bf9\u4e8e\u6211\u5bb6\u65cf\u7684\u6069\u8d50[00:15.340]
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    final line = model.lines.firstWhere(
      (l) => l.start == const Duration(milliseconds: 2392),
    );
    expect(
      line.translation,
      '\u4e07\u798f\u739b\u5229\u4e9a \u611f\u8c22\u60a8\u5bf9\u4e8e\u6211\u5bb6\u65cf\u7684\u6069\u8d50',
    );
  });

  test('parse enhanced translation line with same start timestamp', () {
    const lrc = '''
[00:01.000]Hello [00:01.500]world[00:02.000]
[00:01.000]\u4f60\u597d[00:01.500]\u4e16\u754c[00:02.000]
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    final line = model.lines.firstWhere(
      (l) => l.start == const Duration(seconds: 1),
    );
    expect(line.text, 'Hello world');
    expect(line.translation, '\u4f60\u597d\u4e16\u754c');
    expect(line.words?.map((w) => w.text).join(), 'Hello world');
  });
}
