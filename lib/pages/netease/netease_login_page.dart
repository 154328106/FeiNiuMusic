import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/services/netease/netease_api_client.dart';
import '../../app/services/netease/netease_models.dart';
import '../../components/index.dart';

/// 网易云扫码登录。
///
/// 网易云的扫码流程是「取 key → 生成二维码 → 轮询状态」：登录成功时凭据是靠
/// 响应的 `Set-Cookie`（MUSIC_U）落下来的，客户端不需要自己解析 token。
class NetEaseLoginPage extends StatefulWidget {
  const NetEaseLoginPage({super.key});

  @override
  State<NetEaseLoginPage> createState() => _NetEaseLoginPageState();
}

class _NetEaseLoginPageState extends State<NetEaseLoginPage> {
  final _api = NetEaseApiClient.instance;

  String? _key;
  String? _qrContent;
  String _status = '正在获取二维码…';
  bool _expired = false;
  bool _done = false;
  Timer? _pollTimer;

  /// 每次重新取码自增，用来作废上一轮还在飞的轮询。
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _startLogin();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLogin() async {
    final session = ++_session;
    _pollTimer?.cancel();
    setState(() {
      _qrContent = null;
      _expired = false;
      _done = false;
      _status = '正在获取二维码…';
    });
    try {
      final key = await _api.qrKey();
      if (!mounted || session != _session) return;
      setState(() {
        _key = key;
        _qrContent = _api.qrLoginUrl(key);
        _status = '请用网易云音乐 App 扫码';
      });
      // 3 秒一轮：网易云自己的客户端也是这个量级，再密只是白打请求。
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _poll(session),
      );
    } on NetEaseApiException catch (e) {
      if (!mounted || session != _session) return;
      setState(() => _status = '获取二维码失败：${e.message}');
    }
  }

  Future<void> _poll(int session) async {
    final key = _key;
    if (key == null || !mounted || session != _session) return;
    final status = await _api.qrCheck(key);
    if (!mounted || session != _session) return;
    switch (status) {
      case NetEaseQrStatus.waiting:
        setState(() => _status = '请用网易云音乐 App 扫码');
      case NetEaseQrStatus.scanned:
        setState(() => _status = '已扫码，请在手机上确认登录');
      case NetEaseQrStatus.authorized:
        _pollTimer?.cancel();
        setState(() {
          _done = true;
          _status = '登录成功';
        });
        // 拉一次账号信息，既验证 Cookie 真的可用，也把昵称带回上一页。
        try {
          final user = await _api.account();
          if (!mounted) return;
          Navigator.of(context).pop(user);
        } catch (_) {
          if (!mounted) return;
          Navigator.of(context).pop(true);
        }
      case NetEaseQrStatus.expired:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _status = '二维码已过期';
        });
      case NetEaseQrStatus.unknown:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: '网易云登录'),
      showMiniPlayer: false,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                alignment: Alignment.center,
                child: _buildQrArea(scheme),
              ),
              const SizedBox(height: 24),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: _done ? scheme.primary : scheme.onSurface,
                ),
              ),
              if (_expired) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: _startLogin,
                  child: const Text('重新获取'),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '登录后才能读取你的收藏、每日推荐和播放记录。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrArea(ColorScheme scheme) {
    final content = _qrContent;
    if (content == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        QrImageView(
          data: content,
          size: 208,
          backgroundColor: Colors.white,
          // 二维码本身必须是深色前景，不跟随主题 —— 深色模式下反色会扫不出。
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
        if (_expired)
          Container(
            width: 208,
            height: 208,
            color: Colors.white.withValues(alpha: 0.85),
            alignment: Alignment.center,
            child: const Text('已过期', style: TextStyle(color: Colors.black54)),
          ),
      ],
    );
  }
}
