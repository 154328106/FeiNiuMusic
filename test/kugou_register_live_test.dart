// 酷狗设备注册真实联网测试：KG_LIVE=1 才跑（CI 和平时都跳过）。
// 同一 IP 短时间内连着注册，后面几次会回 data: []，两次之间至少隔 90 秒。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/kugou/kugou_api_client.dart';
import 'package:feiniu_music/app/services/kugou/kugou_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    '免登录注册设备能拿到 dfid',
    () async {
      SharedPreferences.setMockInitialValues({});
      final auth = KugouAuth.instance;
      await auth.ensureLoaded();
      expect(auth.hasDfid, isFalse);
      await KugouApiClient.instance.registerDevice();
      expect(auth.hasDfid, isTrue, reason: '注册后应拿到 dfid');
    },
    skip: Platform.environment['KG_LIVE'] == '1' ? false : '设 KG_LIVE=1 才跑',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
