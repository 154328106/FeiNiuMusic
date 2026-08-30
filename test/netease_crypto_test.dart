import 'dart:convert';

import 'package:feiniu_music/app/services/netease/netease_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 参考向量由 Node.js 内置 `crypto`（OpenSSL）独立生成，用于交叉验证
/// Dart 侧 AES/RSA 实现与网易云客户端一致。生成脚本见 PR 说明：
///   aes-128-cbc(key=0CoJUm6Qyw8W8jud, iv=0102030405060708)
///   aes-128-ecb(key=e82ckenh8dichen8)
///   RAW RSA: m^65537 mod n，输出左补零到 128 字节
void main() {
  group('NetEaseCrypto.weapi', () {
    test('固定随机密钥下 params/encSecKey 与 OpenSSL 参考实现逐字节一致', () {
      final result = NetEaseCrypto.weapi({
        'type': 3,
      }, secretKeyOverride: 'abcdefghijklmnop');

      expect(result['params'], 'KvY3feRTl6uX5m5cjNDgaQOWOzCp89c7N5+8+KFFOZ4=');
      expect(
        result['encSecKey'],
        'd15a1683c992095d0c234c19966605c5c5964911268bbeda8cb8d08d834913e5'
        '9d53b32358903a121b5fca784c1f5ae44951fd02524df58ecc98e52cc7cf8689'
        'b42c2e93ddf05b0592512d87f5960467e2f086c018849d76014d323500e30f13'
        'ef4cafbb0cf5a66731a3f1776c75ca35d0062dac70a3e33245afabcf47938487',
      );
    });

    test('encSecKey 恒为 256 位 hex（不足左补零）', () {
      for (var i = 0; i < 20; i++) {
        final result = NetEaseCrypto.weapi({'type': 3});
        final key = result['encSecKey']!;
        expect(key.length, 256);
        expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(key), isTrue);
      }
    });

    test('params 是合法 base64', () {
      final result = NetEaseCrypto.weapi({'id': 123, 'level': 'standard'});
      expect(() => base64.decode(result['params']!), returnsNormally);
    });

    test('随机密钥每次不同（params 不应重复）', () {
      final a = NetEaseCrypto.weapi({'type': 3})['params'];
      final b = NetEaseCrypto.weapi({'type': 3})['params'];
      expect(a, isNot(b));
    });
  });

  group('NetEaseCrypto.eapi', () {
    test('params 与 OpenSSL 参考实现逐字节一致', () {
      final result = NetEaseCrypto.eapi({
        'type': 3,
      }, '/api/login/qrcode/unikey');

      expect(
        result['params'],
        '1ca81a97b7baeb099f29a9b99a25cd6e58e7ba5b35f25231033065c776830c0a'
        '38a128cf8b3eaf44635e50e0b9800a4a037cbda1e04bd460c02768e3ecd5e66e'
        '905a5bcae52009fb0933efb373a62e834048debdabccc627f25820a8d94e0a8c',
      );
    });

    test('输出是确定性的（无随机成分）', () {
      final a = NetEaseCrypto.eapi({'type': 3}, '/api/login/qrcode/unikey');
      final b = NetEaseCrypto.eapi({'type': 3}, '/api/login/qrcode/unikey');
      expect(a['params'], b['params']);
    });

    test('path 参与摘要：路径不同则密文不同', () {
      final a = NetEaseCrypto.eapi({'type': 3}, '/api/login/qrcode/unikey');
      final b = NetEaseCrypto.eapi({'type': 3}, '/api/song/lyric');
      expect(a['params'], isNot(b['params']));
    });

    test('只产出 params 一个字段（eapi 不带 encSecKey）', () {
      final result = NetEaseCrypto.eapi({
        'type': 3,
      }, '/api/login/qrcode/unikey');
      expect(result.keys.toList(), ['params']);
    });
  });

  group('NetEaseCrypto.rawRsaEncryptHex', () {
    test('与 OpenSSL 参考实现一致', () {
      expect(
        NetEaseCrypto.rawRsaEncryptHex('hello'),
        '5f43c0d20224f1db186d6a6728f25fa33b69f20e467775bc8d9c52332b7ea80d'
        'b0026630bb56d878cf702fcb16c3cf86c2eee256d14752b27258c8cd964bcec7'
        'aec42c5cdbadb1da660b9f143ec3ba32d318b2d55f265efdb1147405c5af00d3'
        '203d33d3b5784f14ae1ba3dd5db981d69ce06f2bb3ca13b38fd574fcdf8400ab',
      );
    });

    test('无 padding：相同输入恒得相同输出', () {
      expect(
        NetEaseCrypto.rawRsaEncryptHex('ponmlkjihgfedcba'),
        NetEaseCrypto.rawRsaEncryptHex('ponmlkjihgfedcba'),
      );
    });
  });
}
