import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_island_lyric.dart';

void main() {
  setUp(() {
    IslandLyricSettings.resetForTest();
  });

  test('island lyric settings load, save, and default to disabled', () async {
    SharedPreferences.setMockInitialValues({
      'island_lyric_enabled': false,
    });

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.enabled.value, false);

    await IslandLyricSettings.setEnabled(true);
    expect(IslandLyricSettings.enabled.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_enabled'), true);
  });

  test('island lyric settings default show progress on', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.showProgress.value, true);

    await IslandLyricSettings.setShowProgress(false);
    expect(IslandLyricSettings.showProgress.value, false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_show_progress'), false);
  });

  test('island lyric settings test mode defaults off and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.testMode.value, false);

    await IslandLyricSettings.setTestMode(true);
    expect(IslandLyricSettings.testMode.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_test_mode'), true);
  });

  test('island lyric settings aod lyrics defaults off and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.aodLyrics.value, false);

    await IslandLyricSettings.setAodLyrics(true);
    expect(IslandLyricSettings.aodLyrics.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_aod_lyrics'), true);
  });
}
