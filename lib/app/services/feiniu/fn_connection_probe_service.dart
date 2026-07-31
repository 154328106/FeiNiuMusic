import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/settings_fn_state.dart';
import 'fn_models.dart';

/// FN 连接探测服务（单例）
///
/// 核心职责：
/// 1. 调用 FN 接口获取连接参数
/// 2. 按优先级分层探测可用链路（1 秒超时）
/// 3. 返回首个可用的连接地址
///
/// 探测规则：
/// - 内网 IPv4 永久最高优先级
/// - HTTPS 端口优先于 HTTP
/// - 公网优先模式探测公网 IPv6 → IPv4 → 中继
/// - 中继优先模式跳过公网直连
/// - 所有单链路探测 1 秒超时
class FnConnectionProbeService {
  FnConnectionProbeService._();

  static final FnConnectionProbeService instance = FnConnectionProbeService._();

  /// FN 接口签名常量
  static const String _authxPrefix = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
  static const String _apiKey = 'zIGtkc3dqZnJpd29qZXJqa2w7c';

  /// 是否正在探测中
  final ValueNotifier<bool> isProbing = ValueNotifier(false);

  /// 独立 Dio 实例，不与主 API 客户端共享配置
  final Dio _probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      followRedirects: false,
    ),
  );

  CancelToken? _cancelToken;

  /// 执行分层探测
  ///
  /// [fnId] - FNID（如 "kuilei0926"）
  /// [order] - 连接优先级顺序，默认读 [AppFnConnectionSettings.connectionOrder]
  /// [preferHttps] - 直连组内是否优先 HTTPS，默认读 [AppFnConnectionSettings.preferHttps]
  ///
  /// 返回 [ConnectionProbeResult]，包含最终成功的 URL。
  /// 所有链路失败时抛出 [Exception]。
  Future<ConnectionProbeResult> probe({
    required String fnId,
    List<ProbeCandidateGroup>? order,
    bool? preferHttps,
  }) async {
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      // Step 1: 调用 FN API 获取连接参数
      if (kDebugMode) {
        debugPrint('[FnProbe] Fetching connection params for fnId=$fnId');
      }
      final params = await _callFnConnectionApi(fnId, _cancelToken!);

      // Step 2: 分层探测
      if (kDebugMode) {
        debugPrint('[FnProbe] Starting hierarchical probe');
      }
      final result = await _hierarchicalProbe(
        fnId,
        params,
        cancelToken: _cancelToken!,
        order: order ?? AppFnConnectionSettings.connectionOrder.value,
        preferHttps: preferHttps ?? AppFnConnectionSettings.preferHttps.value,
      );

      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Probe succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 取消当前探测
  void cancel() {
    _cancelToken?.cancel();
  }

  /// 缓存优先探测（仅升级，不降级）
  ///
  /// 下次打开优先验证上次成功连接的 URL 是否仍可用（200ms 快探）：
  /// - 缓存可达：仅探测优先级高于缓存的候选，若更高优先级链路可达则自动切换（升级）；
  ///   否则保持缓存连接（不降级）。
  /// - 缓存不可达或已不在当前候选列表（陈旧地址）：回退到完整分层探测。
  ///
  /// [cachedUrl] - 上次成功连接的 URL（来自 AppFnConnectionSettings）
  /// [cachedIsRelay] - 上次连接是否为中继模式
  /// [fnId] - FNID
  /// [order] - 连接优先级顺序，默认读 [AppFnConnectionSettings.connectionOrder]
  /// [preferHttps] - 直连组内是否优先 HTTPS，默认读 [AppFnConnectionSettings.preferHttps]
  ///
  /// 返回 [ConnectionProbeResult]，包含最终成功的 URL。
  /// 所有链路失败时抛出 [Exception]。
  Future<ConnectionProbeResult> probeSmart({
    required String fnId,
    String? cachedUrl,
    bool cachedIsRelay = false,
    List<ProbeCandidateGroup>? order,
    bool? preferHttps,
  }) async {
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }

    final effOrder = order ?? AppFnConnectionSettings.connectionOrder.value;
    final effHttps = preferHttps ?? AppFnConnectionSettings.preferHttps.value;

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      if (kDebugMode) {
        debugPrint('[FnProbe] Trying cached connection: $cachedUrl');
      }

      // Step 1: 获取参数并构建按优先级排序的候选列表
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: effOrder,
        preferHttps: effHttps,
      );

      // Step 2: 缓存优先快探
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        final cachedIndex = candidates.indexWhere(
          (c) => c.address == cachedUrl,
        );
        if (cachedIndex >= 0) {
          final cacheOk = await _tryCachedAddress(
            cachedUrl,
            cachedIsRelay,
            _cancelToken!,
          );
          if (cacheOk) {
            if (_cancelToken!.isCancelled) throw Exception('探测已取消');

            // 探测优先级更高的候选（索引 < cachedIndex），首个可达者即升级
            final better = candidates.sublist(0, cachedIndex);
            if (better.isNotEmpty) {
              final results = await Future.wait(
                better.map((c) => _tryAddressWithDetail(c, _cancelToken!)),
              );
              for (var i = 0; i < results.length; i++) {
                if (_cancelToken!.isCancelled) throw Exception('探测已取消');
                if (results[i].isReachable) {
                  if (kDebugMode) {
                    debugPrint(
                      '[FnProbe] ✓ Upgraded (priority ${i + 1}): ${results[i].description}',
                    );
                  }
                  return ConnectionProbeResult(
                    serverUrl: results[i].address,
                    probeMethod: results[i].description,
                    isRelay: results[i].isRelay,
                  );
                }
              }
            }

            // 无更高优先级可达，保持缓存连接
            if (kDebugMode) {
              debugPrint('[FnProbe] Cached connection still valid: $cachedUrl');
            }
            return ConnectionProbeResult(
              serverUrl: cachedUrl,
              probeMethod: '缓存连接',
              isRelay: cachedIsRelay,
            );
          }
          // 缓存不可达 → 回退完整探测
        }
        // 缓存不在当前候选列表（陈旧地址）→ 忽略缓存，完整探测
      }

      // Step 3: 完整分层探测
      final result = await _hierarchicalProbe(
        fnId,
        params,
        cancelToken: _cancelToken!,
        order: effOrder,
        preferHttps: effHttps,
      );

      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Full probe succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 快速验证缓存连接是否可达（200ms 快探）
  Future<bool> _tryCachedAddress(
    String url,
    bool isRelay,
    CancelToken cancelToken,
  ) async {
    try {
      await _probeDio.getUri(
        Uri.parse(url),
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: const Duration(milliseconds: 200),
          receiveTimeout: const Duration(seconds: 1),
          sendTimeout: const Duration(seconds: 1),
          followRedirects: false,
          validateStatus: (_) => true,
          headers: isRelay ? {'Cookie': 'mode=relay'} : null,
        ),
      );
      return true;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      return false;
    }
  }

  /// 调用 FN 接口获取连接参数
  Future<FnConnectionParams> _callFnConnectionApi(
    String fnId,
    CancelToken cancelToken,
  ) async {
    const apiPath = '/api/v1/fn/con';
    final url = 'https://5ddd.com$apiPath';
    final data = {'fnId': fnId};

    final response = await _probeDio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: Options(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'authx': _computeAuthx('post', apiPath, data)},
      ),
    );

    final parsed = FnConnectionResponse.fromJson(
      response.data as Map<String, dynamic>,
    );

    if (!parsed.isSuccess || parsed.data == null) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : 'FNID 查询失败，请检查输入');
    }

    return parsed.data!;
  }

  /// 计算 authx 签名请求头
  ///
  /// 注意：url 参数必须传相对路径（如 /api/v1/fn/con），
  /// 服务端签名校验用的是路径部分，不是完整 URL。
  ///
  /// 算法：
  ///   raw = PREFIX + url + nonce + timestamp + md5(参数) + apiKey
  ///   sign = md5(raw)
  ///   authx = nonce=xxx&timestamp=xxx&sign=xxx
  static String _computeAuthx(String method, String url, dynamic data) {
    final c = method == 'get'
        ? _sortAndSerializeQuery(data as Map<String, dynamic>?)
        : jsonEncode(data);
    final nonce = (Random().nextInt(900000) + 100000).toString().padLeft(
      6,
      '0',
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final raw = [
      _authxPrefix,
      url,
      nonce,
      timestamp,
      _md5(c),
      _apiKey,
    ].join('_');
    final sign = _md5(raw);
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  static String _md5(String input) {
    return crypto.md5.convert(utf8.encode(input)).toString();
  }

  static String _sortAndSerializeQuery(Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) return '';
    final keys = params.keys.toList()..sort();
    return keys
        .map((k) => '$k=${Uri.encodeComponent(params[k].toString())}')
        .join('&');
  }

  /// 探测所有候选链路（用于「FN Connect」设置页完整展示）
  ///
  /// 与 [probe] 不同，此方法会探测*所有*候选地址并返回完整结果列表，
  /// 同时返回首个可用连接。
  ///
  /// 返回一个元组：(所有候选结果列表, 首个成功的 [ConnectionProbeResult] 或 null)
  Future<
    ({
      List<ProbeCandidateResult> candidates,
      ConnectionProbeResult? firstSuccess,
    })
  >
  probeAllCandidates({
    required String fnId,
    List<ProbeCandidateGroup>? order,
    bool? preferHttps,
  }) async {
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: order ?? AppFnConnectionSettings.connectionOrder.value,
        preferHttps: preferHttps ?? AppFnConnectionSettings.preferHttps.value,
      );

      // 并行探测所有候选（默认所有候选中继模式共 4 条以上，并行可加速）
      final results = await Future.wait(
        candidates.map((c) => _tryAddressWithDetail(c, _cancelToken!)),
      );

      final firstSuccess = results
          .where((r) => r.isReachable)
          .map(
            (r) => ConnectionProbeResult(
              serverUrl: r.address,
              probeMethod: r.description,
              isRelay: r.isRelay,
            ),
          )
          .firstOrNull;

      return (candidates: results, firstSuccess: firstSuccess);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 并发探测所有候选地址，按优先级取首个可用
  Future<ConnectionProbeResult> _hierarchicalProbe(
    String fnId,
    FnConnectionParams params, {
    required CancelToken cancelToken,
    required List<ProbeCandidateGroup> order,
    required bool preferHttps,
  }) async {
    final candidates = buildProbeCandidateSpecs(
      fnId: fnId,
      params: params,
      order: order,
      preferHttps: preferHttps,
    );

    // 并发探测所有候选
    final results = await Future.wait(
      candidates.map((c) => _tryAddressWithDetail(c, cancelToken)),
    );

    // 按原始优先级顺序取第一个可达的
    for (var i = 0; i < results.length; i++) {
      if (cancelToken.isCancelled) {
        throw Exception('探测已取消');
      }
      final r = results[i];
      if (r.isReachable) {
        if (kDebugMode) {
          debugPrint(
            '[FnProbe] ✓ Success (priority ${i + 1}): ${r.description}',
          );
        }
        return ConnectionProbeResult(
          serverUrl: r.address,
          probeMethod: r.description,
          isRelay: r.isRelay,
        );
      }
    }

    // 全部失败
    final errors = results
        .where((r) => !r.isReachable && r.error != null)
        .take(5)
        .map((r) => '${r.description}: ${r.error}')
        .join('\n');
    final totalFailed = results.where((r) => !r.isReachable).length;
    final suffix = totalFailed > 5 ? '\n...以及其他 ${totalFailed - 5} 个地址' : '';
    throw Exception('所有链路均无法连接，请检查网络或稍后重试。\n$errors$suffix');
  }

  /// 探测单条链路并返回探测结果详情
  Future<ProbeCandidateResult> _tryAddressWithDetail(
    ProbeCandidateSpec candidate,
    CancelToken cancelToken,
  ) async {
    try {
      final options = Options(
        connectTimeout: const Duration(seconds: 1),
        receiveTimeout: const Duration(seconds: 1),
        sendTimeout: const Duration(seconds: 1),
        followRedirects: false,
        validateStatus: (_) => true,
        headers: candidate.relayMode ? {'Cookie': 'mode=relay'} : null,
      );

      await _probeDio.getUri(
        Uri.parse(candidate.address),
        options: options,
        cancelToken: cancelToken,
      );

      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: true,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: false,
        error: _dioErrorMessage(e),
      );
    }
  }

  String _dioErrorMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.receiveTimeout:
        return '响应超时';
      case DioExceptionType.sendTimeout:
        return '发送超时';
      case DioExceptionType.connectionError:
        return '网络连接错误';
      case DioExceptionType.badResponse:
        return '服务器返回错误 (${e.response?.statusCode})';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return e.message ?? '未知网络错误';
    }
  }
}
