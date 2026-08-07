import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/player/mini_player/mini_player_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerService.instance.currentSong.value = const SongEntity(
      id: 'song-1',
      title: '测试歌曲',
      artist: '[{"guid":"a1","name":"测试歌手"}]',
    );
  });

  tearDown(() {
    PlayerService.instance.currentSong.value = null;
  });

  Widget buildBar({double width = 360}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: MiniPlayerBar(),
          ),
        ),
      ),
    );
  }

  testWidgets('右滑浮现「上一曲」提示', (tester) async {
    await tester.pumpWidget(buildBar());
    await tester.pump();

    // 初始无提示（opacity 0）
    Opacity opacityOf(String text) {
      final textWidget = tester.widget<Text>(find.text(text));
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
      );
      return opacity;
    }

    expect(opacityOf('上一曲').opacity, 0);

    // 右滑 40px（未过阈值，仅提示）
    await tester.drag(find.byType(MiniPlayerBar), const Offset(40, 0));
    await tester.pump();
    expect(opacityOf('上一曲').opacity, greaterThan(0));
    expect(opacityOf('下一曲').opacity, 0);

    // 松手回弹后提示淡出
    await tester.pumpAndSettle();
    expect(opacityOf('上一曲').opacity, 0);
  });

  testWidgets('左滑浮现「下一曲」提示', (tester) async {
    await tester.pumpWidget(buildBar());
    await tester.pump();

    Opacity opacityOf(String text) {
      return tester.widget<Opacity>(
        find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
      );
    }

    expect(opacityOf('下一曲').opacity, 0);

    await tester.drag(find.byType(MiniPlayerBar), const Offset(-40, 0));
    await tester.pump();
    expect(opacityOf('下一曲').opacity, greaterThan(0));
    expect(opacityOf('上一曲').opacity, 0);

    await tester.pumpAndSettle();
    expect(opacityOf('下一曲').opacity, 0);
  });
}
