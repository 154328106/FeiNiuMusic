import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/services/qq/qq_auth.dart';
import '../../components/index.dart';

/// QQ 音乐扫码登录。
///
/// 和网易云那页最大的不同：网易云给的是一个 key、由客户端自己画二维码；
/// QQ 直接返回一张 PNG，所以这里是 [Image.memory] 而不是 QrImageView。
/// 二维码有效期约两分钟，过期后点一下重新拉一张。
class QQLoginPage extends StatefulWidget {
  const QQLoginPage({super.key});

  @override
  State<QQLoginPage> createState() => _QQLoginPageState();
}

class _QQLoginPageState extends State<QQLoginPage> {
  final QQAuth _auth = QQAuth.instance;

  Uint8List? _qrImage;
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
      _hint = '用手机 QQ 扫码授权';
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
      case QQScanState.waiting:
        break;
      case QQScanState.scanned:
        setState(() => _hint = '已扫描，请在手机上确认');
      case QQScanState.expired:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _hint = '二维码已过期，点一下重新获取';
        });
      case QQScanState.error:
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _hint = result.message ?? '登录失败，点一下重试';
        });
      case QQScanState.success:
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
      appBar: const AppTopBar(title: '扣扣音乐登录', showBackButton: true),
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
                '登录后可以听会员曲、拿更高音质。\n不登录也能用推荐、榜单和搜索。',
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
