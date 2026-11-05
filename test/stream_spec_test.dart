import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/stream_spec.dart';

void main() {
  test('按文件头认格式', () {
    expect(StreamSpec.formatOf('fLaC....'.codeUnits), 'FLAC');
    expect(StreamSpec.formatOf('ID3.....'.codeUnits), 'MP3');
    expect(StreamSpec.formatOf([0xFF, 0xFB, 0x90, 0x00]), 'MP3');
    expect(
      StreamSpec.formatOf([0, 0, 0, 0x20, ...'ftypM4A '.codeUnits]),
      'M4A',
    );
    expect(StreamSpec.formatOf('OggS....'.codeUnits), 'OGG');
    expect(StreamSpec.formatOf('<html>'.codeUnits), isNull);
  });

  test('拼成「FLAC · 32.4MB · 约 960kbps」', () {
    // 32.4MB、270 秒 → 约 1007kbps
    expect(
      StreamSpec.compose('FLAC', (32.4 * 1048576).round(), 270000),
      'FLAC · 32.4MB · 约 1007kbps',
    );
    // 320k mp3：10.3MB / 269s ≈ 321kbps
    expect(
      StreamSpec.compose('MP3', (10.3 * 1048576).round(), 269000),
      'MP3 · 10.3MB · 约 321kbps',
    );
    expect(StreamSpec.compose('M4A', 0, 0), 'M4A');
    expect(StreamSpec.compose(null, 100, 100), isNull);
  });
}
