import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';

/// 探测的鉴权校验（fnProbeResponseUsable）：
///
/// 登录后探测携带当前 token，候选地址必须通过带鉴权的 API 请求才算「可用」。
/// 否则 TCP 可达但 token 被拒的地址（如切到与登录凭据不匹配的服务器 IP，
/// 日志表现为 INVALID TOKEN / 401）会被误选为连接，导致后续全部请求失败。
/// 登录前无 token 时退化为纯 TCP 可达性探测（一律视为可用）。
void main() {
  Response<dynamic> r(int status, [Map<String, dynamic>? data]) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: 'http://x'),
        statusCode: status,
        data: data,
      );

  group('fnProbeResponseUsable', () {
    test('未鉴权检查（登录前 TCP-only）时一律可用', () {
      expect(fnProbeResponseUsable(r(200), authChecked: false), isTrue);
      expect(fnProbeResponseUsable(r(401), authChecked: false), isTrue);
      expect(fnProbeResponseUsable(r(500), authChecked: false), isTrue);
    });

    test('HTTP 401/403 → 不可用（token 被拒）', () {
      expect(fnProbeResponseUsable(r(401), authChecked: true), isFalse);
      expect(fnProbeResponseUsable(r(403), authChecked: true), isFalse);
    });

    test('HTTP 5xx → 不可用（服务端错误）', () {
      expect(fnProbeResponseUsable(r(500), authChecked: true), isFalse);
      expect(fnProbeResponseUsable(r(503), authChecked: true), isFalse);
    });

    test('业务码 0 → 可用', () {
      expect(
        fnProbeResponseUsable(r(200, {'code': 0}), authChecked: true),
        isTrue,
      );
    });

    test('业务码非 0（如 INVALID TOKEN）→ 不可用', () {
      expect(
        fnProbeResponseUsable(r(200, {'code': 401}), authChecked: true),
        isFalse,
      );
      expect(
        fnProbeResponseUsable(
          r(200, {'code': -1, 'msg': 'INVALID TOKEN'}),
          authChecked: true,
        ),
        isFalse,
      );
    });

    test('200 且无业务码 → 可用（兜底）', () {
      expect(fnProbeResponseUsable(r(200), authChecked: true), isTrue);
    });
  });
}
