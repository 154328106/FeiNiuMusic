/// FNID 连接参数相关数据模型
library;

/// FN 接口响应（POST https://5ddd.com/api/v1/fn/con）
class FnConnectionResponse {
  final int code;
  final String msg;
  final FnConnectionParams? data;

  const FnConnectionResponse({required this.code, required this.msg, this.data});

  bool get isSuccess => code == 0;

  factory FnConnectionResponse.fromJson(Map<String, dynamic> json) {
    return FnConnectionResponse(
      code: json['code'] as int? ?? -1,
      msg: json['msg'] as String? ?? '',
      data: json['data'] != null
          ? FnConnectionParams.fromJson(json['data'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// FN 接口返回的连接参数
///
/// 实际接口响应示例：
/// {"ddns":null,"ipv4":["192.168.11.200","192.168.11.205","192.168.11.201"],
///  "ipv6":[],"publicIpv4":["120.239.64.67"],
///  "publicIpv6":["2409:...","2409:...",...],   // 6条
///  "fn":["kuilei0926.5ddd.com:443"],
///  "port":{"httpsPort":5667,"httpPort":5666},
///  "checkSum":"24756","ver":"3.0.0","forbbidPublicIpv6":false}
class FnConnectionParams {
  /// 内网 IPv4 地址列表（接口字段：ipv4）
  final List<String> internalIPv4s;

  /// 公网 IPv4 地址列表（接口字段：publicIpv4，数组）
  final List<String> publicIPv4s;

  /// 公网 IPv6 地址列表（接口字段：publicIpv6）
  final List<String> publicIPv6s;

  /// HTTPS 端口（接口字段：port.httpsPort，默认 5667）
  final int httpsPort;

  /// HTTP 端口（接口字段：port.httpPort，默认 5666）
  final int httpPort;

  /// 中继地址列表（接口字段：fn，如 ["kuilei0926.5ddd.com:443"]）
  final List<String> relayAddresses;

  const FnConnectionParams({
    required this.internalIPv4s,
    required this.publicIPv4s,
    required this.publicIPv6s,
    required this.httpsPort,
    required this.httpPort,
    required this.relayAddresses,
  });

  factory FnConnectionParams.fromJson(Map<String, dynamic> json) {
    // 解析 port 嵌套对象
    final port = json['port'] as Map<String, dynamic>? ?? {};

    return FnConnectionParams(
      internalIPv4s: (json['ipv4'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      publicIPv4s: (json['publicIpv4'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      publicIPv6s: (json['publicIpv6'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      httpsPort: port['httpsPort'] as int? ?? 5667,
      httpPort: port['httpPort'] as int? ?? 5666,
      relayAddresses: (json['fn'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}

/// 连接偏好模式
enum FnConnectionPreference {
  /// 公网优先（默认）
  /// 内网→IPv6→IPv4→中继
  publicFirst,

  /// 中继优先
  /// 内网→中继（跳过公网直连）
  relayFirst,
}

/// 连接探测结果
class ConnectionProbeResult {
  /// 探测成功的服务器 URL
  final String serverUrl;

  /// 成功方式的描述
  final String probeMethod;

  /// 是否为中继链路连接
  final bool isRelay;

  const ConnectionProbeResult({
    required this.serverUrl,
    required this.probeMethod,
    this.isRelay = false,
  });
}

/// 候选链路分组
enum ProbeCandidateGroup {
  internal,
  publicIPv6,
  publicIPv4,
  relay,
}

/// 单条候选链路探测结果
///
/// 用于「FN Connect」设置页完整展示所有候选链路状态。
class ProbeCandidateResult {
  /// 候选地址
  final String address;

  /// 连接方式描述
  final String description;

  /// 分组
  final ProbeCandidateGroup group;

  /// 归属 IP 标识（用于组内分组显示，中继为 null）
  final String? ipLabel;

  /// 是否为中继
  final bool isRelay;

  /// 是否可达（已探测并存结果）
  final bool isReachable;

  /// 不可达时的错误描述（null 表示未探测或可达）
  final String? error;

  const ProbeCandidateResult({
    required this.address,
    required this.description,
    required this.group,
    this.ipLabel,
    this.isRelay = false,
    required this.isReachable,
    this.error,
  });

  /// 分组中文标题
  String get groupTitle => switch (group) {
        ProbeCandidateGroup.internal => '内网',
        ProbeCandidateGroup.publicIPv6 => '公网 IPv6',
        ProbeCandidateGroup.publicIPv4 => '公网 IPv4',
        ProbeCandidateGroup.relay => '中继',
      };

  /// 分组排序优先级
  int get groupOrder => switch (group) {
        ProbeCandidateGroup.internal => 0,
        ProbeCandidateGroup.publicIPv6 => 1,
        ProbeCandidateGroup.publicIPv4 => 2,
        ProbeCandidateGroup.relay => 3,
      };
}
