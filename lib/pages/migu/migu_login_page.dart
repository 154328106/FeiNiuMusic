import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/services/migu/migu_auth.dart';
import '../../components/index.dart';

/// 咪咕音乐扫码登录。
///
/// 咪咕 passport 直接返回一张 JPEG 二维码（base64），所以用 [Image.memory]。
/// 二维码约两分钟过期，过期后点一下重新拉一张。登录后能解锁咪咕自家直连的
/// VIP 高音质地址；不登录也能用搜索、歌手、播放（走聚合音源）。
class MiguLoginPage extends StatefulWidget {
  const MiguLoginPage({super.key});

  @override
  State<MiguLoginPage> createState() => _MiguLoginPageState();
}

class _MiguLoginPageState extends State<MiguLoginPage> {
  final MiguAuth _auth = MiguAuth.instance;

  Uint8List? _qrImage;
  String _hint = '正在获取二维码…';
  bool _loading = true;
  bool _expired = false;
  Timer? _pollTimer;

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
      _qrImage = null;
      _hint = '正在获取二维码…';
    });

    final image = await _auth.fetchQrCode();
    if (!mounted || session != _session) return;
    if (image == null) {
      setState(() {
        _loading = false;
        _expired = true;
        _hint = '获取二维码失败，点一下重试';
      });
      return;
    }
    setState(() {
      _qrImage = image;
      _loading = false;
      _hint = '用手机咪咕音乐 App 扫码授权';
    });
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _poll(session),
    );
  }

  Future<void> _poll(int session) async {
    if (!mounted || session != _session) return;
    final result = await _auth.poll();
    if (!mounted || session != _session) return;
    switch (result.state) {
      case MiguScanState.waiting:
        break;
      case MiguScanState.scanned:
        setState(() => _hint = '已扫描，请在手机上确认');
      case MiguScanState.expired:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _hint = '二维码已过期，点一下重新获取';
        });
      case MiguScanState.error:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _hint = result.message ?? '登录失败，点一下重试';
        });
      case MiguScanState.success:
        _pollTimer?.cancel();
        if (!mounted) return;
        final nick = result.nickname?.trim();
        AppToast.showGlobal(
          (nick == null || nick.isEmpty) ? '登录成功' : '登录成功：$nick',
        );
        Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: '咪咕音乐登录', showBackButton: true),
      showMiniPlayer: false,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
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
                '登录后可解锁咪咕自家的 VIP 高音质直链。\n不登录也能用搜索、歌手和播放（走聚合音源）。',
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
    final image = _qrImage;
    if (image == null) {
      return Icon(
        Icons.refresh_rounded,
        size: 48,
        color: scheme.onSurfaceVariant,
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Image.memory(image, width: 200, height: 200),
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
