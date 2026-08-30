import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// 网易云音乐接口加密。
///
/// 网易云的 web/pc 接口不接受明文参数，请求体必须按两套方案之一加密：
///
/// - **weapi**（`/weapi/*`，网页端）：明文 JSON 先用固定密钥 AES-128-CBC 加密，
///   base64 后再用一个随机 16 位密钥二次 AES-128-CBC 加密得到 `params`；随机
///   密钥**反转**后走 RAW RSA（`m^65537 mod n`，**无 padding**）得到 `encSecKey`。
///   两个字段一起 form-urlencoded 提交。
/// - **eapi**（`/eapi/*`，客户端）：明文拼成带 md5 摘要的固定格式串，再用固定
///   密钥 AES-128-ECB 加密，hex 编码后作为单个 `params` 字段提交。
///
/// 常量取自网易云客户端，属于公开的固定值，不是密钥材料。
class NetEaseCrypto {
  NetEaseCrypto._();

  /// weapi 第一层 AES 的固定密钥。
  static final Uint8List _fixedKey = Uint8List.fromList(
    utf8.encode('0CoJUm6Qyw8W8jud'),
  );

  /// weapi 两层 AES-CBC 共用的固定 IV。
  static final Uint8List _fixedIv = Uint8List.fromList(
    utf8.encode('0102030405060708'),
  );

  /// eapi AES-ECB 的固定密钥。
  static final Uint8List _eapiKey = Uint8List.fromList(
    utf8.encode('e82ckenh8dichen8'),
  );

  /// RAW RSA 的 1024 位模数（公钥指数固定 65537）。
  static final BigInt _rsaModulus = BigInt.parse(
    'e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152'
    'b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecb'
    'da92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d81'
    '3cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7',
    radix: 16,
  );

  static final BigInt _rsaExponent = BigInt.from(65537);

  static const String _secretChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  static final Random _random = Random.secure();

  /// weapi 加密，返回待提交的 `params` / `encSecKey` 表单字段。
  ///
  /// [secretKeyOverride] 仅供测试注入固定随机密钥用，正常调用不要传。
  static Map<String, String> weapi(
    Map<String, dynamic> payload, {
    String? secretKeyOverride,
  }) {
    final text = jsonEncode(payload);
    final first = _aesCbcEncrypt(
      Uint8List.fromList(utf8.encode(text)),
      _fixedKey,
    );
    final secretKey = secretKeyOverride ?? _randomSecretKey();
    final second = _aesCbcEncrypt(
      Uint8List.fromList(utf8.encode(base64.encode(first))),
      Uint8List.fromList(utf8.encode(secretKey)),
    );
    // 反转后再加密：网易云服务端按反转顺序还原密钥。
    final reversed = String.fromCharCodes(secretKey.runes.toList().reversed);
    return {
      'params': base64.encode(second),
      'encSecKey': rawRsaEncryptHex(reversed),
    };
  }

  /// eapi 加密，返回待提交的 `params` 表单字段。
  ///
  /// [path] 是接口的 **api 路径**（如 `/api/song/enhance/player/url/v1`），
  /// 不是实际请求的 `/eapi/...` 路径——摘要按 api 路径计算。
  static Map<String, String> eapi(Map<String, dynamic> payload, String path) {
    final text = jsonEncode(payload);
    final digest = crypto.md5
        .convert(utf8.encode('nobody${path}use${text}md5forencrypt'))
        .toString();
    final data = '$path-36cd479b6b5-$text-36cd479b6b5-$digest';
    final params = _aesEcbEncrypt(
      Uint8List.fromList(utf8.encode(data)),
      _eapiKey,
    );
    return {'params': _hex(params)};
  }

  /// RAW RSA（`m^e mod n`，无 padding），返回 256 位小写 hex（左侧补零）。
  ///
  /// 明文按大端解释为整数。网易云要求固定 128 字节输出，短了要补零，
  /// 否则服务端解不出密钥。
  static String rawRsaEncryptHex(String input) {
    final bytes = utf8.encode(input);
    var message = BigInt.zero;
    for (final b in bytes) {
      message = (message << 8) | BigInt.from(b);
    }
    final result = message.modPow(_rsaExponent, _rsaModulus);
    return result.toRadixString(16).padLeft(256, '0');
  }

  // ---------------------------------------------------------------------
  // AES 原语
  // ---------------------------------------------------------------------

  static Uint8List _aesCbcEncrypt(Uint8List input, Uint8List key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), _fixedIv),
        null,
      ),
    );
    return cipher.process(input);
  }

  static Uint8List _aesEcbEncrypt(Uint8List input, Uint8List key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
        KeyParameter(key),
        null,
      ),
    );
    return cipher.process(input);
  }

  static String _randomSecretKey() => List.generate(
    16,
    (_) => _secretChars[_random.nextInt(_secretChars.length)],
  ).join();

  static String _hex(Uint8List data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
