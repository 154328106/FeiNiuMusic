import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/backup/backup_service.dart';
import 'package:feiniu_music/app/services/migu/migu_auth.dart';
import 'package:feiniu_music/app/services/netease/netease_api_client.dart';
import 'package:feiniu_music/app/services/qq/qq_auth.dart';
import 'package:feiniu_music/app/services/unblock/unblock_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourcesOnly = BackupSections(
    accounts: false,
    stats: false,
    settings: false,
    sources: true,
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('BackupSections 默认包含「音源与平台登录」', () {
    expect(const BackupSections().sources, isTrue);
    expect(sourcesOnly.any, isTrue);
  });

  test('音源与平台登录：导出 → 清空 → 还原，偏好写回且各服务立刻重载', () async {
    SharedPreferences.setMockInitialValues({
      'netease.cookies': jsonEncode({'MUSIC_U': 'nu', '__csrf': 'c'}),
      'qq.auth.cookies': jsonEncode({'qqmusic_key': 'qk', 'uin': '1'}),
      'qq.auth.nickname': 'QQ昵称',
      'migu.auth.cookies': jsonEncode({'SESSION': 'ms'}),
      'migu.auth.nickname': '咪咕昵称',
      'kugou.auth.v1': jsonEncode({'userid': '9', 'token': 'kt'}),
      'unblock.source.preferLx': true,
      'unblock.source.freeFallback': false,
      'setting_theme': 'dark', // 普通设置：不属于音源分块
    });
    await NetEaseApiClient.instance.reloadFromStorage();
    await UnblockSourceService.instance.reloadFromStorage();

    final jsonStr = await BackupService.instance.buildBackupJson(sourcesOnly);
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final prefsOut =
        (data['sources'] as Map<String, dynamic>)['prefs']
            as Map<String, dynamic>;
    expect(
      prefsOut.keys,
      containsAll([
        'netease.cookies',
        'qq.auth.cookies',
        'qq.auth.nickname',
        'migu.auth.cookies',
        'kugou.auth.v1',
        'unblock.source.preferLx',
      ]),
    );
    expect(
      prefsOut.containsKey('setting_theme'),
      isFalse,
      reason: '普通设置不应混进音源分块',
    );

    // 换一台「空」设备：内存里的服务先按空存档加载（模拟已经启动过的 App）
    SharedPreferences.setMockInitialValues({});
    await NetEaseApiClient.instance.reloadFromStorage();
    await QQAuth.instance.reloadFromStorage();
    await MiguAuth.instance.reloadFromStorage();
    await UnblockSourceService.instance.reloadFromStorage();
    expect(NetEaseApiClient.instance.isLoggedIn, isFalse);
    expect(UnblockSourceService.instance.preferLxEnabled.value, isFalse);

    final summary = await BackupService.instance.restoreFromJson(jsonStr);
    expect(summary, contains('音源与平台登录'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kugou.auth.v1'), contains('kt'));
    expect(prefs.getString('setting_theme'), isNull);
    // 不用重启：内存里的服务已按还原后的存档重载
    expect(NetEaseApiClient.instance.isLoggedIn, isTrue);
    expect(QQAuth.instance.nickname, 'QQ昵称');
    expect(MiguAuth.instance.isLoggedIn.value, isTrue);
    expect(UnblockSourceService.instance.preferLxEnabled.value, isTrue);
    expect(UnblockSourceService.instance.freeFallbackEnabled.value, isFalse);
  });

  test('没勾「音源与平台登录」时不导出也不还原该分块', () async {
    SharedPreferences.setMockInitialValues({
      'netease.cookies': jsonEncode({'MUSIC_U': 'nu'}),
    });
    final jsonStr = await BackupService.instance.buildBackupJson(
      const BackupSections(
        accounts: false,
        stats: false,
        settings: false,
        sources: false,
      ),
    );
    expect((jsonDecode(jsonStr) as Map).containsKey('sources'), isFalse);
  });
}
