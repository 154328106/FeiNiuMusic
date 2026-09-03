import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/services/kugou/kugou_api_client.dart';
import '../../app/services/kugou/kugou_models.dart';
import '../../components/index.dart';

/// 酷狗音乐扫码登录。
///
/// 和 QQ 那页的差别：酷狗返回的是一段 key，二维码要自己画（和网易云一样），
/// 所以这里用 [QrImageView] 而不是 [Image.memory]。
///
/// 登录成功后还会顺手注册一次设备换 dfid —— 会员曲的取址接口认那个值，
/// 光有 token 是不够的。这一步在 [KugouApiClient.pollQr] 里做掉了。
class KugouLoginPage extends StatefulWidget {
  const KugouLoginPage({super.key});

  @override
  State<KugouLoginPage> createState() => _KugouLoginPageState();
}

class _KugouLoginPageState extends State<KugouLoginPage> {
  final KugouApiClient _api = KugouApiClient.instance;

  String? _qrKey;
  String _hint = '正在获取二维码…';
  bool _loading = true;
  bool _expired = false;
  Timer? _pollTimer;

  /// 每次重新取码自增：旧的轮询回来时按 session 丢弃，避免两轮并行。
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _pollTimer?.cancel();
    final session = ++_session;
    setState(() {
      _loading = true;
      _expired = false;
      _qrKey = null;
      _hint = '正在获取二维码…';
    });

    String key;
    try {
      key = await _api.qrKey();
    } catch (e) {
      if (!mounted || session != _session) return;
      setState(() {
        _loading = false;
        _expired = true;
        _hint = '获取二维码失败，点一下重试';
      });
      debugPrint('[KugouLogin] 取码失败：$e');
      return;
    }
    if (!mounted || session != _session) return;
    setState(() {
      _qrKey = key;
      _loading = false;
      _hint = '用酷狗音乐 App 扫码';
    });
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _poll(session, key),
    );
  }

  /// 上一发轮询还没回来时，定时器的下一发直接跳过。
  ///
  /// 不拦的话，一次慢响应会让好几发查询叠在一起 —— 扫码成功那一刻尤其明显，
  /// 每一发都会各自走一遍「保存登录 + 注册设备」。
  bool _polling = false;

  Future<void> _poll(int session, String key) async {
    if (!mounted || session != _session || _polling) return;
    _polling = true;
    final KugouScanResult result;
    try {
      result = await _api.pollQr(key);
    } catch (e) {
      // 网络抖动就等下一轮，不要因为一次失败把码作废。
      debugPrint('[KugouLogin] 轮询失败：$e');
      return;
    } finally {
      _polling = false;
    }
    // 扫码不自动返回这件事查了两轮还没定位，光靠推测不行了 —— 把每一步
    // 都打出来：轮询拿到什么状态、到没到 success、pop 有没有真的执行。
    debugPrint(
      '[KugouLogin] 轮询状态=${result.state.name} '
      'mounted=$mounted session=$session/$_session',
    );
    if (!mounted || session != _session) return;
    switch (result.state) {
      case KugouScanState.waiting:
        break;
      case KugouScanState.scanned:
        setState(() => _hint = '已扫描，请在手机上确认');
      case KugouScanState.expired:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _hint = '二维码已过期，点一下重新获取';
        });
      case KugouScanState.success:
        _pollTimer?.cancel();
        if (!mounted) return;
        final nick = result.nickname?.trim();
        AppToast.showGlobal(
          (nick == null || nick.isEmpty) ? '登录成功' : '登录成功：$nick',
        );
        final navigator = Navigator.of(context);
        debugPrint('[KugouLogin] 准备返回，canPop=${navigator.canPop()}');
        navigator.pop(true);
        debugPrint('[KugouLogin] pop 已执行');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: '酷狗音乐登录', showBackButton: true),
      showMiniPlayer: false,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                // 过期 / 失败时整块可点，重新取一张。
                onTap: _expired ? _start : null,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: _buildQr(scheme),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _hint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Text(
                '登录后可以听会员曲、拿更高音质，还能同步云端歌单。\n'
                '不登录也能用推荐、榜单和搜索。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQr(ColorScheme scheme) {
    if (_loading) return const CircularProgressIndicator();
    final key = _qrKey;
    if (key == null) {
      return Icon(
        Icons.refresh_rounded,
        size: 48,
        color: scheme.onSurfaceVariant,
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        QrImageView(
          data:
              'https://h5.kugou.com/apps/loginQRCode/html/index.html'
              '?qrcode=$key',
          size: 200,
          backgroundColor: Colors.white,
        ),
        // 过期时盖一层白纱 + 刷新图标，别让人对着一张废码扫。
        if (_expired)
          Container(
            width: 200,
            height: 200,
            color: Colors.white.withValues(alpha: 0.82),
            alignment: Alignment.center,
            child: Icon(Icons.refresh_rounded, size: 44, color: scheme.primary),
          ),
      ],
    );
  }
}
