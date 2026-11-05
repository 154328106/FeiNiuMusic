import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lxscript/lx_source_manager.dart';
import 'package:feiniu_music/app/services/unblock/expiring_set.dart';
import 'package:feiniu_music/app/services/unblock/unblock_source.dart';

/// 2026-11-05「不管什么情况都要保证能播」：设置自相矛盾 / 脚本给死链 /
/// 一次失败就整场跳歌，这几种情况 App 要自己绕开。
///
/// 注意：不调 TestWidgetsFlutterBinding.ensureInitialized() —— 它会拦掉
/// 真实 HTTP（一律回 400），linkAlive 要连本机起的测试服务器。
void main() {
  group('ExpiringSet：取不到的标记会过期', () {
    test('过期前算取不到，过期后自动放行', () async {
      final s = ExpiringSet<String>(const Duration(milliseconds: 50));
      expect(s.add('a'), isTrue);
      expect(s.contains('a'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(s.contains('a'), isFalse);
    });

    test('remove / clear', () {
      final s = ExpiringSet<int>(const Duration(minutes: 10))
        ..add(1)
        ..add(2);
      expect(s.remove(1), isTrue);
      expect(s.contains(1), isFalse);
      s.clear();
      expect(s.contains(2), isFalse);
    });
  });

  group('免费兜底：关了但什么都没配，照样用', () {
    final svc = UnblockSourceService.instance;

    tearDown(() {
      svc.freeFallbackEnabled.value = true;
      svc.config.value = UnblockSourceConfig.empty;
    });

    test('关了兜底 + 没配聆澜 + 没有启用的脚本 → 仍然用免费音源', () {
      svc.freeFallbackEnabled.value = false;
      svc.config.value = UnblockSourceConfig.empty;
      expect(LxSourceManager.instance.hasEnabled, isFalse);
      expect(svc.freeFallbackActive, isTrue);
    });

    test('关了兜底 + 聆澜配好了 → 尊重用户，只用聆澜', () {
      svc.freeFallbackEnabled.value = false;
      svc.config.value = const UnblockSourceConfig(
        template: UnblockSourceConfig.defaultTemplate,
        apiKeys: ['k'],
      );
      expect(svc.freeFallbackActive, isFalse);
    });

    test('开着兜底 → 用', () {
      svc.freeFallbackEnabled.value = true;
      expect(svc.freeFallbackActive, isTrue);
    });
  });

  group('脚本给的链接先敲门', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final res = req.response;
        switch (req.uri.path) {
          case '/audio':
            res.statusCode = 206;
            res.headers.contentType = ContentType('audio', 'mpeg');
            res.add([0xff, 0xfb]);
          case '/missing':
            res.statusCode = 404;
            res.headers.contentType = ContentType.html;
            res.write('<html>404</html>');
          case '/errorpage':
            res.headers.contentType = ContentType.html;
            res.write('<html>出错了</html>');
          case '/json':
            res.statusCode = 403;
            res.headers.contentType = ContentType.json;
            res.write('{"code":403,"msg":"未授权客户端"}');
          case '/broken':
            res.statusCode = 502;
          case '/redirect':
            res.statusCode = 302;
            res.headers.set('location', '$base/audio');
          case '/forbidden':
            // 403 但没说是网页：可能只是防盗链认 UA，放行交给播放器
            res.statusCode = 403;
        }
        await res.close();
      });
    });

    tearDownAll(() => server.close(force: true));

    test('正常音频（含跳转）→ 能用', () async {
      expect(await LxSourceManager.linkAlive('$base/audio'), isTrue);
      expect(await LxSourceManager.linkAlive('$base/redirect'), isTrue);
    });

    test('404 / 错误网页 / JSON 报错 / 5xx → 丢弃', () async {
      expect(await LxSourceManager.linkAlive('$base/missing'), isFalse);
      expect(await LxSourceManager.linkAlive('$base/errorpage'), isFalse);
      expect(await LxSourceManager.linkAlive('$base/json'), isFalse);
      expect(await LxSourceManager.linkAlive('$base/broken'), isFalse);
    });

    test('拿不准的放行：裸 403、连不上的端口照实判', () async {
      expect(await LxSourceManager.linkAlive('$base/forbidden'), isTrue);
      // 端口没人听：连接被拒，播放器一样连不上
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      expect(
        await LxSourceManager.linkAlive('http://127.0.0.1:$deadPort/x'),
        isFalse,
      );
    });
  });
}
