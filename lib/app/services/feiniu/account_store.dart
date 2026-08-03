import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_fn_state.dart';
import '../../utils/cache_version_store.dart';
import '../../utils/page_cache_store.dart';
import '../db/dao/song_dao.dart';
import '../player_service.dart';
import 'account_entry.dart';
import 'api_client.dart';
import 'auth_service.dart';

/// 已保存账号列表管理（单例）
///
/// 现有 SharedPreferences key（feiniu_music_token / feiniu_server_url /
/// feiniu_relay_mode / fn_access_code / feiniu_username / feiniu_password /
/// fn_last_fnid）继续作为「当前激活账号槽位」——描述内存中已加载的账号。
/// 本类是已保存账号列表的唯一数据源，每次激活/切换都把所选账号的字段写入
/// 该槽位，让现有加载逻辑（tryLoadAuth、登录页自动填充、启动预热探测）无需改动。
class AccountStore {
  AccountStore._();

  static final AccountStore instance = AccountStore._();

  /// 已保存账号列表（有序，最近登录/创建的靠前）
  final ValueNotifier<List<AccountEntry>> accounts = ValueNotifier([]);

  /// 当前激活账号 id（与「激活槽位」保持一致）
  final ValueNotifier<String?> currentAccountId = ValueNotifier(null);

  static const String _prefsAccounts = 'feiniu_accounts_v1';
  static const String _prefsCurrentAccountId = 'feiniu_current_account_id';

  bool _initialized = false;

  bool get isInitialized => _initialized;

  AccountEntry? get currentAccount {
    final id = currentAccountId.value;
    if (id == null) return null;
    return byId(id);
  }

  AccountEntry? byId(String id) {
    for (final e in accounts.value) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 初始化：加载列表 + 首启迁移 + 校正当前账号。
  ///
  /// 需在 [AuthService.init]（已恢复激活槽位）之后调用；会自行确保
  /// [AppFnConnectionSettings] 已加载（读取安全码 / FNID）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    FeiNiuApiClient.instance.onTokenCleared = onTokenExpired;
    await AppFnConnectionSettings.ensureLoaded();

    final prefs = await SharedPreferences.getInstance();
    await _loadAccounts(prefs);

    // 首启迁移：列表为空但激活槽位有有效会话 → 导入为第一个账号
    if (accounts.value.isEmpty) {
      final api = FeiNiuApiClient.instance;
      if (api.token.isNotEmpty && api.baseUrl.isNotEmpty) {
        final entry = AccountEntry(
          id: _generateId(),
          serverUrl: api.baseUrl,
          username: prefs.getString('feiniu_username') ?? '',
          password: prefs.getString('feiniu_password'),
          token: api.token,
          relayMode: api.relayMode,
          accessCode: AppFnConnectionSettings.accessCode,
          fnId: AppFnConnectionSettings.lastFnId,
          createdAt: DateTime.now(),
        );
        accounts.value = [entry];
        currentAccountId.value = entry.id;
      }
    }

    _reconcileCurrent();
    await _persist();
    if (kDebugMode) {
      debugPrint(
        '[AccountStore] init: ${accounts.value.length} account(s), '
        'current=${currentAccount?.displayName}',
      );
    }
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _initialized = false;
    accounts.value = [];
    currentAccountId.value = null;
    FeiNiuApiClient.instance.onTokenCleared = null;
  }

  Future<void> _loadAccounts(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsAccounts);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          accounts.value = decoded
              .whereType<Map<String, dynamic>>()
              .map(AccountEntry.fromJson)
              .toList();
        }
      } catch (_) {
        // 数据损坏则丢弃，视为无账号
      }
    }
    final cid = prefs.getString(_prefsCurrentAccountId);
    if (cid != null && cid.isNotEmpty) {
      currentAccountId.value = cid;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsAccounts,
      jsonEncode(accounts.value.map((e) => e.toJson()).toList()),
    );
    final cid = currentAccountId.value;
    if (cid == null) {
      await prefs.remove(_prefsCurrentAccountId);
    } else {
      await prefs.setString(_prefsCurrentAccountId, cid);
    }
  }

  /// 按 id 替换列表中的条目（无则追加），并通知。
  void _replaceInList(AccountEntry entry) {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == entry.id);
    if (index >= 0) {
      list[index] = entry;
    } else {
      list.add(entry);
    }
    accounts.value = list;
  }

  /// 校正当前账号：id 无效时按「激活槽位匹配 → 列表第一个」回退。
  void _reconcileCurrent() {
    final list = accounts.value;
    if (list.isEmpty) {
      currentAccountId.value = null;
      return;
    }
    if (currentAccountId.value != null &&
        byId(currentAccountId.value!) != null) {
      return;
    }
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isNotEmpty) {
      final activeIdentity =
          '${api.baseUrl.trim()}::${AuthService.instance.username.value ?? ''}';
      for (final e in list) {
        if (e.identityKey == activeIdentity) {
          currentAccountId.value = e.id;
          return;
        }
      }
    }
    currentAccountId.value = list.first.id;
  }

  // ── CRUD ────────────────────────────────────────────────────────────

  /// 新增或更新账号（按 [AccountEntry.identityKey] 去重）。
  ///
  /// 命中已有账号时：保留用户自定义备注 [AccountEntry.name]，但若本次传入的
  /// [AccountEntry.name] 非空则以本次为准（用户明确输入了新备注）；覆盖其余字段。
  /// 返回规范化后的条目。
  Future<AccountEntry> addOrUpdate(AccountEntry entry) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere(
      (e) => e.identityKey == entry.identityKey,
    );
    AccountEntry canonical;
    if (index >= 0) {
      final existing = list[index];
      canonical = existing.copyWith(
        serverUrl: entry.serverUrl,
        username: entry.username,
        password: () => entry.password,
        token: entry.token,
        relayMode: entry.relayMode,
        accessCode: () => entry.accessCode,
        fnId: () => entry.fnId,
        // 本次明确输入了备注则以本次为准，否则保留已有自定义备注
        name: entry.name.isNotEmpty ? entry.name : null,
      );
      list[index] = canonical;
    } else {
      canonical = AccountEntry(
        id: entry.id.isNotEmpty ? entry.id : _generateId(),
        name: _uniqueAutoName(list, entry),
        serverUrl: entry.serverUrl,
        username: entry.username,
        password: entry.password,
        token: entry.token,
        relayMode: entry.relayMode,
        accessCode: entry.accessCode,
        fnId: entry.fnId,
        createdAt: DateTime.now(),
      );
      list.add(canonical);
    }
    accounts.value = list;
    await _persist();
    return canonical;
  }

  /// 重命名账号备注。
  Future<void> rename(String id, String name) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    list[index] = list[index].copyWith(name: name.trim());
    accounts.value = list;
    await _persist();
  }

  /// 编辑账号服务器标识。
  ///
  /// 自动识别输入内容：
  /// - 以 http/https 开头 → 视为服务器地址，更新 [AccountEntry.serverUrl] 并清除 FNID；
  /// - 否则 → 视为 FNID，更新 [AccountEntry.fnId]（去掉可能的 .5ddd.com 后缀）。
  ///
  /// token 绑定服务器/FNID，修改后清空该账号 token（需重新登录）。
  Future<void> updateServerUrl(String id, String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final current = list[index];

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final normalized = _normalizeUrl(trimmed);
      if (normalized.isEmpty || current.serverUrl == normalized) return;
      list[index] = current.copyWith(
        serverUrl: normalized,
        fnId: () => null,
        token: '',
      );
    } else {
      // 视为 FNID，去掉可能带的后缀
      var fnId = trimmed;
      if (fnId.endsWith('.5ddd.com')) {
        fnId = fnId.substring(0, fnId.length - '.5ddd.com'.length);
      }
      if (current.fnId == fnId) return;
      list[index] = current.copyWith(fnId: () => fnId, token: '');
    }
    accounts.value = list;
    await _persist();
  }

  /// 删除账号。删除的是当前账号时，currentAccountId 回退到剩余第一个或 null。
  Future<void> remove(String id) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    list.removeAt(index);
    accounts.value = list;
    if (currentAccountId.value == id) {
      currentAccountId.value = list.isEmpty ? null : list.first.id;
    }
    await _persist();
  }

  /// 登录成功后捕获账号并入列表（供登录页调用）。
  Future<AccountEntry> persistLogin({
    required String serverUrl,
    required String username,
    required String password,
    required bool relayMode,
    String? fnId,
    String name = '',
  }) async {
    final api = FeiNiuApiClient.instance;
    final entry = await addOrUpdate(
      AccountEntry(
        id: _generateId(),
        name: name,
        serverUrl: serverUrl.isNotEmpty ? serverUrl : api.baseUrl,
        username: username,
        password: password.isNotEmpty ? password : null,
        token: api.token,
        relayMode: relayMode,
        accessCode: AppFnConnectionSettings.accessCode,
        fnId: fnId,
        createdAt: DateTime.now(),
      ),
    );
    currentAccountId.value = entry.id;
    await _persist();
    return entry;
  }

  /// 登录成功后将结果写回指定账号（编辑账号场景，保留原 id 与自定义备注）。
  ///
  /// 用户改完服务器地址/用户名/备注后重新登录，用新身份更新该账号：
  /// - 覆盖 serverUrl / username / token / relayMode / accessCode / fnId / password；
  /// - 若 [name] 非空则以新备注为准，否则保留原有自定义备注。
  /// 若指定 id 不存在则退化为 [persistLogin] 的新增逻辑。
  Future<AccountEntry> persistLoginForEdit({
    required String id,
    required String serverUrl,
    required String username,
    required String password,
    required bool relayMode,
    String? fnId,
    String name = '',
  }) async {
    final api = FeiNiuApiClient.instance;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) {
      return persistLogin(
        serverUrl: serverUrl,
        username: username,
        password: password,
        relayMode: relayMode,
        fnId: fnId,
        name: name,
      );
    }
    final existing = list[index];
    final updated = existing.copyWith(
      serverUrl: serverUrl.isNotEmpty ? serverUrl : api.baseUrl,
      username: username,
      password: () => password.isNotEmpty ? password : null,
      token: api.token,
      relayMode: relayMode,
      accessCode: () => AppFnConnectionSettings.accessCode,
      fnId: () => fnId,
      // 本次输入了备注则以本次为准，否则保留原有自定义备注
      name: name.isNotEmpty ? name : null,
    );
    list[index] = updated;
    accounts.value = list;
    currentAccountId.value = id;
    await _persist();
    return updated;
  }

  // ── 激活 / 切换 ─────────────────────────────────────────────────────

  /// 把 [entry] 写入「当前激活账号槽位」。
  ///
  /// 同步 API 客户端（token/serverUrl/relay）、安全码、连接信息与 AuthService
  /// 各 notifier，使现有加载逻辑与请求头立即生效。
  Future<void> activate(AccountEntry entry) async {
    final api = FeiNiuApiClient.instance;
    if (entry.token.isNotEmpty) {
      await api.setAuth(entry.serverUrl, entry.token, relayMode: entry.relayMode);
    } else {
      await api.clearAuth();
      await api.setBaseUrl(entry.serverUrl);
      api.setRelayMode(entry.relayMode);
    }
    final prefs = await SharedPreferences.getInstance();
    // 无 token 时也写服务器地址/中继标记，保证登录页自动填充与预热探测一致
    await prefs.setString('feiniu_server_url', entry.serverUrl);
    await prefs.setBool('feiniu_relay_mode', entry.relayMode);
    if (entry.username.isNotEmpty) {
      await prefs.setString('feiniu_username', entry.username);
    }
    if (entry.password != null && entry.password!.isNotEmpty) {
      await prefs.setString('feiniu_password', entry.password!);
    } else {
      await prefs.remove('feiniu_password');
    }

    await AppFnConnectionSettings.setAccessCode(entry.accessCode);
    await AppFnConnectionSettings.restoreConnection(
      url: entry.serverUrl,
      isRelay: entry.relayMode,
      fnId: entry.fnId,
      method: (entry.fnId != null && entry.fnId!.isNotEmpty)
          ? 'FNID 连接'
          : '手动连接',
    );

    AuthService.instance.serverUrl.value = entry.serverUrl;
    AuthService.instance.username.value = entry.username;
    AuthService.instance.isLoggedIn.value = entry.token.isNotEmpty;
  }

  /// 切换到另一已保存账号：停止播放 → 清空缓存 → 激活 → 设当前。
  ///
  /// 目标账号 token 有效时直接切换；token 失效/为空但保存了密码时，
  /// 自动用密码重新登录验证后再切换（不跳登录页）；否则 `isLoggedIn` 会
  /// 被置为 false，由门控回退到登录页。
  ///
  /// 返回切换是否成功（无需重新登录的失败场景返回 false，不抛出）。
  Future<bool> switchTo(String id) async {
    final entry = byId(id);
    if (entry == null || id == currentAccountId.value) return false;

    // 停止播放（含清队列/持久化播放状态）
    try {
      await PlayerService.instance.stopAndClear();
    } catch (_) {}
    // 清空内存 API 缓存层
    PageCacheStore.instance.clearAll();
    // 清空 SQLite api_cache 表（不同服务器内容不串）
    try {
      await SongDao.instance.clearApiCache();
    } catch (_) {}
    // 触发缓存版本变更，令依赖缓存版本的页面重新拉取
    CacheVersionStore.instance.bump('song_library');

    // token 失效/为空但有密码 → 自动重新登录验证
    if (entry.token.isEmpty) {
      final password = entry.password;
      if (password == null || password.isEmpty) {
        // 无密码可用，无法自动登录；由门控回退到登录页
        await activate(entry);
        currentAccountId.value = entry.id;
        await _persist();
        return false;
      }
      try {
        final deviceId = AuthService.instance.getOrCreateDeviceId();
        await FeiNiuApiClient.instance.setBaseUrl(entry.serverUrl);
        if (entry.relayMode) {
          FeiNiuApiClient.instance.setRelayMode(true);
        }
        final response = await FeiNiuApiClient.instance.login(
          entry.username,
          password,
          deviceId,
          relayMode: entry.relayMode,
        );
        // 用新 token 更新账号并激活
        final refreshed = entry.copyWith(
          token: response.userToken,
          username: response.username ?? entry.username,
        );
        _replaceInList(refreshed);
        await activate(refreshed);
        currentAccountId.value = refreshed.id;
        await _persist();
        return true;
      } catch (_) {
        // 自动登录失败：激活为空 token 的条目，由门控回退到登录页
        await activate(entry);
        currentAccountId.value = entry.id;
        await _persist();
        return false;
      }
    }

    await activate(entry);
    currentAccountId.value = entry.id;
    await _persist();
    if (kDebugMode) {
      debugPrint('[AccountStore] Switched to ${entry.displayName}');
    }
    return true;
  }

  /// 把激活槽位中的连接信息（探测得到的 URL/中继/安全码/FNID）回写当前账号。
  ///
  /// 仅更新连接字段，绝不动 token。供启动预热与自动重连成功后调用，
  /// 使账号列表与「当前实际使用的连接」保持一致。
  Future<void> syncActiveAccountConnection() async {
    final current = currentAccount;
    if (current == null) return;
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('feiniu_server_url');
    final relay = prefs.getBool('feiniu_relay_mode') ?? false;
    final code = prefs.getString('fn_access_code');
    final fnId = prefs.getString('fn_last_fnid');
    final next = current.copyWith(
      serverUrl: (url != null && url.isNotEmpty) ? url : current.serverUrl,
      relayMode: relay,
      accessCode: () => code,
      fnId: () => (fnId == null || fnId.isEmpty) ? null : fnId,
    );
    if (next == current) return;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == current.id);
    if (index < 0) return;
    list[index] = next;
    accounts.value = list;
    await _persist();
  }

  /// 401 导致激活槽位 token 被清除时同步当前账号（仅清 token，不翻转登录态）。
  void onTokenExpired() {
    final current = currentAccount;
    if (current == null || !current.isLoggedIn) return;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == current.id);
    if (index < 0) return;
    list[index] = current.copyWith(token: '');
    accounts.value = list;
    _persist();
  }

  // ── 工具 ────────────────────────────────────────────────────────────

  static String _generateId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 规范化服务器地址：去掉 /music/api/v1 后缀与末尾斜杠。
  static String _normalizeUrl(String url) {
    var u = url.replaceAll(RegExp(r'/music/api/v1/*$'), '');
    u = u.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// 为新增账号生成唯一自动名（默认「飞牛NAS」，重名追加 " (2)"）。
  static String _uniqueAutoName(List<AccountEntry> list, AccountEntry entry) {
    final base = entry.displayName;
    final used = list
        .map((e) => e.name)
        .where((n) => n.isNotEmpty)
        .toSet();
    if (!used.contains(base)) return base;
    var i = 2;
    while (used.contains('$base ($i)')) {
      i++;
    }
    return '$base ($i)';
  }
}
