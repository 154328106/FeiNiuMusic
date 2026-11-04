import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feiniu_music/app/services/backup/backup_service.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';
import 'package:feiniu_music/app/services/played_song_cache.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 听歌统计还原后排行榜为空：统计数字有了，但在线歌（网易云 / QQ / 酷狗）的
/// 歌名歌手在 PlayedSongCache 里，以前没随统计带走，还原后对不上歌。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const onlineSong = SongEntity(id: 'ne:186016', title: '晴天', artist: '周杰伦');
  const statsOnly = BackupSections(
    accounts: false,
    stats: true,
    settings: false,
    sources: false,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayedSongCache.instance.resetForTest();
    DbHelper.instance.resetForTest(overridePath: inMemoryDatabasePath);
  });

  test('听歌统计带上播放留档；换到空设备还原后能对上歌', () async {
    SharedPreferences.setMockInitialValues({
      'played.songs.v1': jsonEncode([onlineSong.toMap()]),
    });
    PlayedSongCache.instance.resetForTest();

    final jsonStr = await BackupService.instance.buildBackupJson(statsOnly);
    final stats =
        (jsonDecode(jsonStr) as Map<String, dynamic>)['stats']
            as Map<String, dynamic>;
    expect((stats['playedSongs'] as List).length, 1);

    // 空设备：留档里什么都没有（且已被 App 读过一次）
    SharedPreferences.setMockInitialValues({});
    PlayedSongCache.instance.resetForTest();
    await PlayedSongCache.instance.ensureLoaded();
    expect(PlayedSongCache.instance.byIds(['ne:186016']), isEmpty);

    await BackupService.instance.restoreFromJson(jsonStr);
    expect(
      PlayedSongCache.instance.byIds(['ne:186016'])['ne:186016']?.title,
      '晴天',
    );
    // 写回了存档，重启后也还在
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('played.songs.v1'), contains('晴天'));
  });

  tearDown(() => DbHelper.instance.resetForTest());

  test('旧备份：播放留档在「应用设置」里，也按合并还原、不覆盖本机已有的', () async {
    const local = SongEntity(id: 'qq:1', title: '本机的歌', artist: '某人');
    SharedPreferences.setMockInitialValues({
      'played.songs.v1': jsonEncode([local.toMap()]),
    });
    PlayedSongCache.instance.resetForTest();
    await PlayedSongCache.instance.ensureLoaded();

    final legacy = jsonEncode({
      'format': 1,
      'app': 'feiniu_music',
      'settings': {
        'played.songs.v1': {
          't': 's',
          'v': jsonEncode([onlineSong.toMap()]),
        },
      },
    });
    await BackupService.instance.restoreFromJson(legacy);

    final got = PlayedSongCache.instance.byIds(['ne:186016', 'qq:1']);
    expect(got.keys, containsAll(['ne:186016', 'qq:1']));
  });
}
