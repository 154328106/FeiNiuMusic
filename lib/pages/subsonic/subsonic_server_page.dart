import 'package:flutter/material.dart';

import '../../app/services/subsonic/subsonic_api_client.dart';
import '../../app/services/subsonic/subsonic_server.dart';
import '../../components/index.dart';

/// Subsonic 服务器配置页。
///
/// Navidrome、以及 NAS 上 4000 端口那个服务，说的都是 Subsonic 协议，
/// 填同一套地址 / 用户名 / 密码即可。
class SubsonicServerPage extends StatefulWidget {
  const SubsonicServerPage({super.key});

  @override
  State<SubsonicServerPage> createState() => _SubsonicServerPageState();
}

class _SubsonicServerPageState extends State<SubsonicServerPage> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    await SubsonicServerStore.instance.load();
    if (!mounted) return;
    final config = SubsonicServerStore.instance.config.value;
    _urlController.text = config.baseUrl;
    _userController.text = config.username;
    _passwordController.text = config.password;
    setState(() {});
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    var url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _result = '请填写服务器地址';
        _resultOk = false;
      });
      return;
    }
    // 只填了 IP:端口时补上 http://，省得用户每次手打。
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }

    setState(() {
      _testing = true;
      _result = null;
    });

    // 先存再测：客户端从 store 读配置，不存下去测的就是旧的。
    // 认证方式重置回 token —— 换了服务器，上次降级的结论不一定还成立。
    await SubsonicServerStore.instance.save(
      SubsonicServerConfig(
        baseUrl: url,
        username: _userController.text.trim(),
        password: _passwordController.text,
      ),
    );

    try {
      final version = await SubsonicApiClient.instance.ping();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultOk = true;
        _result = '连接成功，服务端版本 $version';
      });
    } on SubsonicApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultOk = false;
        _result = e.code == 40 ? '用户名或密码错误' : '连接失败：${e.message}';
      });
    }
  }

  Future<void> _clear() async {
    await SubsonicServerStore.instance.clear();
    if (!mounted) return;
    _urlController.clear();
    _userController.clear();
    _passwordController.clear();
    setState(() => _result = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPageScaffold(
      appBar: const AppTopBar(title: 'Subsonic 服务器'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppSettingSection(
            title: '连接',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: '例如 192.168.1.10:4000',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _userController,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _testing ? null : _saveAndTest,
            child: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存并测试连接'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _clear, child: const Text('清除配置')),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  _resultOk
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: _resultOk ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _result!,
                    style: TextStyle(
                      color: _resultOk ? scheme.primary : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Navidrome 以及 NAS 上 4000 端口的音乐服务都走 Subsonic 协议，'
            '填同一套信息即可。旧服务端不支持 token 认证时会自动降级为密码认证。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
