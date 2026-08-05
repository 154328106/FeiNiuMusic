import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';

/// 探测超时策略：
/// - 中继/域名候选（relayMode）连接耗时最长（设备 → 5ddd.com CDN → FN 转发），
///   1s 探测窗口对真可达但慢的中继会误判不可达，应放宽到 4s；
/// - 直连 IP 候选仍保持 1s（内网/公网直连通常更快）；
/// - 缓存/回前台校验（connect 200ms）对「慢但可达」的地址误判过激进，应放宽到 1s。
void main() {
  group('探测超时策略', () {
    test('中继候选（relayMode）→ 4s', () {
      expect(
        fnProbeTimeout(true),
        const Duration(seconds: 4),
      );
    });

    test('直连候选（非 relayMode）→ 1s', () {
      expect(
        fnProbeTimeout(false),
        const Duration(seconds: 1),
      );
    });

    test('缓存/回前台校验 connect 超时 → 1s', () {
      expect(
        kFnCachedProbeConnectTimeout,
        const Duration(seconds: 1),
      );
    });
  });
}
