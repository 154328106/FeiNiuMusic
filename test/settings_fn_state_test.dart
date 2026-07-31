import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/fn_models.dart';
import 'package:feiniu_music/app/state/settings_fn_state.dart';

void main() {
  tearDown(() {
    AppFnConnectionSettings.resetForTest();
  });

  test('no stored order → default order and preferHttps true', () async {
    SharedPreferences.setMockInitialValues({});

    await AppFnConnectionSettings.ensureLoaded();

    expect(
      AppFnConnectionSettings.connectionOrder.value,
      kDefaultConnectionOrder,
    );
    expect(AppFnConnectionSettings.preferHttps.value, true);
  });

  test('stored order is normalized and preferHttps loads', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_order': ['publicIPv4', 'relay'],
      'fn_connection_prefer_https': false,
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(AppFnConnectionSettings.connectionOrder.value, [
      ProbeCandidateGroup.publicIPv4,
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.publicIPv6,
    ]);
    expect(AppFnConnectionSettings.preferHttps.value, false);
  });

  test('garbage/duplicate entries are dropped and defaults appended', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_order': ['garbage', 'internal', 'internal'],
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(
      AppFnConnectionSettings.connectionOrder.value,
      kDefaultConnectionOrder,
    );
  });

  test('legacy relayFirst migrates to relay-before-public order', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_preference': 'relayFirst',
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(AppFnConnectionSettings.connectionOrder.value, [
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.publicIPv6,
      ProbeCandidateGroup.publicIPv4,
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('fn_connection_order'), [
      'internal',
      'relay',
      'publicIPv6',
      'publicIPv4',
    ]);
    expect(prefs.getString('fn_connection_preference'), isNull);
  });

  test(
    'setConnectionOrder persists normalized list and updates notifier',
    () async {
      SharedPreferences.setMockInitialValues({});

      await AppFnConnectionSettings.ensureLoaded();

      await AppFnConnectionSettings.setConnectionOrder([
        ProbeCandidateGroup.relay,
        ProbeCandidateGroup.internal,
      ]);

      expect(AppFnConnectionSettings.connectionOrder.value, [
        ProbeCandidateGroup.relay,
        ProbeCandidateGroup.internal,
        ProbeCandidateGroup.publicIPv6,
        ProbeCandidateGroup.publicIPv4,
      ]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('fn_connection_order'), [
        'relay',
        'internal',
        'publicIPv6',
        'publicIPv4',
      ]);
    },
  );

  test('setPreferHttps persists and updates notifier', () async {
    SharedPreferences.setMockInitialValues({});

    await AppFnConnectionSettings.ensureLoaded();

    await AppFnConnectionSettings.setPreferHttps(false);

    expect(AppFnConnectionSettings.preferHttps.value, false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('fn_connection_prefer_https'), false);
  });
}
