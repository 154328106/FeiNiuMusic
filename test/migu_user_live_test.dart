// 咪咕登录后用户数据的真实联网测试：MIGU_PACM_FILE 指向一个 {"pacm": "..."} 的
// 本机文件才跑（凭据不进仓库）。CI 和平时都跳过。
import 'dart:convert';
import 'dart:io';

import 'package:feiniu_music/app/services/migu/migu_api_client.dart';
import 'package:feiniu_music/app/services/migu/migu_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final file = Platform.environment['MIGU_PACM_FILE'] ?? '';
  test(
    '登录后能取到我喜欢 / 今日推荐 / 最近在听',
    () async {
      final saved = jsonDecode(File(file).readAsStringSync()) as Map;
      SharedPreferences.setMockInitialValues({
        'migu.auth.cookies': jsonEncode({'pacmtoken': saved['pacm']}),
      });
      final auth = MiguAuth.instance;
      await auth.ensureLoaded();
      expect(auth.isLoggedIn.value, isTrue);
      final api = MiguApiClient.instance;
      final liked = await api.likedSongs();
      final today = await api.todayRecommend();
      final recent = await api.recentPlayed();
      // ignore: avoid_print
      print(
        '我喜欢 ${liked.length} 首（${liked.take(3).map((s) => '${s.name}-${s.artists}').join('、')}）'
        '｜今日推荐 ${today.length}｜最近在听 ${recent.length}'
        '｜首曲封面 ${liked.first.coverUrl}｜时长 ${liked.first.durationMs}ms',
      );
      expect(liked, isNotEmpty);
      expect(today, isNotEmpty);
      // 续期后的新 pacmtoken 写回本机文件，下次还能用
      File(
        file,
      ).writeAsStringSync(jsonEncode({...saved, 'pacm': auth.pacmToken}));
    },
    skip: file.isEmpty ? '设 MIGU_PACM_FILE 才跑' : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
