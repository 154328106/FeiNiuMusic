import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/feiniu/fn_models.dart';

/// 连接偏好设置（公网优先 / 中继优先）
///
/// 遵循与 AppLayoutSettings 相同的模式：
/// - ValueNotifier 驱动 UI 响应式更新
/// - SharedPreferences 持久化用户选择
class AppFnConnectionSettings {
  static const String _prefsConnectionPreference = 'fn_connection_preference';
  static const String _prefsLastFnId = 'fn_last_fnid';
  static const String _prefsConnectionUrl = 'fn_connection_url';
  static const String _prefsConnectionMethod = 'fn_connection_method';

  /// 当前连接偏好
  static final ValueNotifier<FnConnectionPreference> connectionPreference =
      ValueNotifier(FnConnectionPreference.publicFirst);

  /// 上次使用的 FNID（用于启动时自动探测）
  static String? lastFnId;

  /// 当前实际使用的连接 URL（探测成功后设置）
  static final ValueNotifier<String?> currentConnectionUrl =
      ValueNotifier(null);

  /// 当前连接方式的描述（如"内网 IPv4 HTTPS (192.168.11.200:5667)"）
  static final ValueNotifier<String?> currentConnectionMethod =
      ValueNotifier(null);

  /// 最近一次全量探测结果（每个候选链路的状态）
  ///
  /// 用于「FN Connect」设置页展示完整列表，null 表示从未全量探测过。
  static final ValueNotifier<List<ProbeCandidateResult>?> currentCandidateResults =
      ValueNotifier(null);

  /// FnConnectionParams 摘要字符串（用于判断是否需要重新探测）
  static String? lastProbedFingerprint;

  static Future<void>? _loading;

  /// 懒惰加载：首次调用时从 SharedPreferences 读取
  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();

    // 连接偏好
    final raw = prefs.getString(_prefsConnectionPreference);
    connectionPreference.value = FnConnectionPreference.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => FnConnectionPreference.publicFirst,
    );

    // 上次 FNID
    lastFnId = prefs.getString(_prefsLastFnId);

    // 上次连接信息（用于显示）
    final savedUrl = prefs.getString(_prefsConnectionUrl);
    final savedMethod = prefs.getString(_prefsConnectionMethod);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      currentConnectionUrl.value = savedUrl;
    }
    if (savedMethod != null && savedMethod.isNotEmpty) {
      currentConnectionMethod.value = savedMethod;
    }
  }

  /// 设置连接偏好并持久化
  static Future<void> setConnectionPreference(
    FnConnectionPreference pref, {
    VoidCallback? onPreferenceChanged,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsConnectionPreference, pref.name);
    connectionPreference.value = pref;
    onPreferenceChanged?.call();
  }

  /// 保存本次探测结果（FNID + 连接 URL + 连接方式 + 候选链路列表）
  static Future<void> saveProbeResult({
    required String fnId,
    required String url,
    required String method,
    List<ProbeCandidateResult>? candidateResults,
    String? fingerprint,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLastFnId, fnId);
    await prefs.setString(_prefsConnectionUrl, url);
    await prefs.setString(_prefsConnectionMethod, method);
    lastFnId = fnId;
    currentConnectionUrl.value = url;
    currentConnectionMethod.value = method;
    if (candidateResults != null) {
      currentCandidateResults.value = candidateResults;
    }
    if (fingerprint != null) {
      lastProbedFingerprint = fingerprint;
    }
  }

  /// 清除连接信息（登出时调用）
  static Future<void> clearConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsLastFnId);
    await prefs.remove(_prefsConnectionUrl);
    await prefs.remove(_prefsConnectionMethod);
    lastFnId = null;
    currentConnectionUrl.value = null;
    currentConnectionMethod.value = null;
  }
}
