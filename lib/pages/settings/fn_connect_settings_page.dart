import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../app/services/feiniu/fn_models.dart';
import '../../app/state/settings_fn_state.dart';
import '../../components/index.dart';

/// FN Connect 连接设置页
///
/// 展示当前连接详情、连接偏好、以及本次 FNID 返回的所有候选链路及其状态，
/// 允许用户手动选中任意可用链路进行切换。
class FnConnectSettingsPage extends StatefulWidget {
  const FnConnectSettingsPage({super.key});

  @override
  State<FnConnectSettingsPage> createState() => _FnConnectSettingsPageState();
}

class _FnConnectSettingsPageState extends State<FnConnectSettingsPage> {
  bool _probing = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    AppFnConnectionSettings.ensureLoaded();
  }

  /// 执行全量探测
  Future<void> _startFullProbe({FnConnectionPreference? overridePref}) async {
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) {
      setState(() {
        _errorMessage = '没有可用的 FNID，请先使用 FNID 登录';
      });
      return;
    }

    setState(() {
      _probing = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final pref =
          overridePref ?? AppFnConnectionSettings.connectionPreference.value;
      final result = await FnConnectionProbeService.instance
          .probeAllCandidates(fnId: fnId, preference: pref);

      if (!mounted) return;

      // 保存探测结果
      if (result.firstSuccess != null) {
        final success = result.firstSuccess!;
        await AppFnConnectionSettings.saveProbeResult(
          fnId: fnId,
          url: success.serverUrl,
          method: success.probeMethod,
          candidateResults: result.candidates,
          isRelay: success.isRelay,
        );

        // 更新 API 客户端
        final currentBase = FeiNiuApiClient.instance.baseUrl;
        if (currentBase != success.serverUrl) {
          await FeiNiuApiClient.instance.setBaseUrl(success.serverUrl);
        }
        FeiNiuApiClient.instance.setRelayMode(success.isRelay);

        setState(() {
          _successMessage = '已切换至: ${success.probeMethod}';
        });
      } else {
        // 全部不可达
        AppFnConnectionSettings.currentCandidateResults.value = result.candidates;
        setState(() {
          _errorMessage = '所有链路均无法连接';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      }
    }
  }

  /// 切换到指定候选地址
  Future<void> _switchToCandidate(ProbeCandidateResult candidate) async {
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;

    try {
      await FeiNiuApiClient.instance.setBaseUrl(candidate.address);
      FeiNiuApiClient.instance.setRelayMode(candidate.isRelay);
      await AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: candidate.address,
        method: candidate.description,
        isRelay: candidate.isRelay,
      );

      if (!mounted) return;
      setState(() {
        _successMessage = '已切换至: ${candidate.description}';
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '切换失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(context);

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: 'FN Connect',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          // === 当前连接 ===
          ValueListenableBuilder<String?>(
            valueListenable: AppFnConnectionSettings.currentConnectionUrl,
            builder: (context, url, _) {
              final displayUrl = (url != null && url.isNotEmpty)
                  ? url
                  : FeiNiuApiClient.instance.baseUrl;
              if (displayUrl.isEmpty) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<String?>(
                valueListenable:
                    AppFnConnectionSettings.currentConnectionMethod,
                builder: (context, method, _) {
                  final methodText = method ?? '';
                  final isRelay = methodText.toLowerCase().contains('中继');
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isRelay
                              ? Icons.swap_horiz_rounded
                              : Icons.link_rounded,
                          size: 22,
                          color: isRelay ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    isRelay ? '中继连接' : '直连',
                                    style: theme.textTheme.titleSmall
                                        ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isRelay
                                          ? Colors.orange
                                              .withValues(alpha: 0.15)
                                          : Colors.green
                                              .withValues(alpha: 0.15),
                                      borderRadius:
                                          BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isRelay ? '中继' : '直连',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isRelay
                                            ? Colors.orange.shade700
                                            : Colors.green.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                displayUrl,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (methodText.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  methodText,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),

          // === 连接偏好 ===
          AppSettingSection(
            title: '连接偏好',
            children: [
              ValueListenableBuilder<FnConnectionPreference>(
                valueListenable:
                    AppFnConnectionSettings.connectionPreference,
                builder: (context, currentPref, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<FnConnectionPreference>(
                        title: const Text('公网优先'),
                        subtitle: const Text(
                          '内网 → 公网 IPv6 → IPv4 → 中继兜底',
                        ),
                        value: FnConnectionPreference.publicFirst,
                        groupValue: currentPref,
                        onChanged: (value) {
                          if (value == null) return;
                          _setPreference(value);
                        },
                      ),
                      RadioListTile<FnConnectionPreference>(
                        title: const Text('中继优先'),
                        subtitle: const Text(
                          '内网 → 跳过公网直连，直接中继连接',
                        ),
                        value: FnConnectionPreference.relayFirst,
                        groupValue: currentPref,
                        onChanged: (value) {
                          if (value == null) return;
                          _setPreference(value);
                        },
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 忽略 SSL 证书校验 ===
          AppSettingSection(
            title: '安全',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppFnConnectionSettings.ignoreSsl,
                builder: (context, ignoreSsl, _) {
                  return SwitchListTile(
                    title: const Text('忽略 SSL 证书校验'),
                    subtitle: const Text('自签名证书或 IP 直连时开启'),
                    value: ignoreSsl,
                    onChanged: (value) {
                      AppFnConnectionSettings.setIgnoreSsl(value);
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 候选链路列表 ===
          AppSettingSection(
            title: '候选链路',
            children: [
              ValueListenableBuilder<List<ProbeCandidateResult>?>(
                valueListenable:
                    AppFnConnectionSettings.currentCandidateResults,
                builder: (context, results, _) {
                  if (results == null || results.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '尚未探测，点击下方按钮开始全量探测',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }

                  // 按分组排序并分组显示，组内再按 IP 分割
                  final grouped = <ProbeCandidateGroup, List<ProbeCandidateResult>>{};
                  for (final r in results) {
                    grouped.putIfAbsent(r.group, () => []).add(r);
                  }
                  final sortedGroups = grouped.entries.toList()
                    ..sort((a, b) => a.value.first.groupOrder.compareTo(b.value.first.groupOrder));

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: sortedGroups.expand((entry) {
                      final title = entry.value.first.groupTitle;
                      final items = <Widget>[];

                      // 组标题
                      items.add(
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 12, 0, 6),
                          child: Text(
                            title,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );

                      // 组内按 ipLabel 分割
                      final byIp = <String?, List<ProbeCandidateResult>>{};
                      for (final r in entry.value) {
                        byIp.putIfAbsent(r.ipLabel, () => []).add(r);
                      }
                      final ipEntries = byIp.entries.toList();
                      for (var i = 0; i < ipEntries.length; i++) {
                        final ipEntry = ipEntries[i];
                        // IP 分割线（中继无 ipLabel，不加）
                        if (i > 0) {
                          items.add(
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Divider(
                                height: 4,
                                indent: 32,
                                endIndent: 32,
                                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                              ),
                            ),
                          );
                        }
                        items.addAll(
                          ipEntry.value.map((candidate) => _CandidateTile(
                            candidate: candidate,
                            onTap: candidate.isReachable
                                ? () => _switchToCandidate(candidate)
                                : null,
                          )),
                        );
                      }
                      return items;
                    }).toList(),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 状态信息 ===
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (_successMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _successMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // === 重新探测按钮 ===
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _probing ? null : _startFullProbe,
              icon: _probing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(_probing ? '正在探测中...' : '重新探测'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // === FNID 信息（非交互，仅供参考） ===
          if (AppFnConnectionSettings.lastFnId != null)
            Center(
              child: Text(
                'FNID: ${AppFnConnectionSettings.lastFnId}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setPreference(FnConnectionPreference pref) {
    if (FnConnectionProbeService.instance.isProbing.value) {
      FnConnectionProbeService.instance.cancel();
    }
    AppFnConnectionSettings.setConnectionPreference(
      pref,
      onPreferenceChanged: () {
        // 偏好变化后自动重新探测
        _startFullProbe(overridePref: pref);
      },
    );
  }
}

/// 单条候选链路 Tile
class _CandidateTile extends StatelessWidget {
  final ProbeCandidateResult candidate;
  final VoidCallback? onTap;

  const _CandidateTile({
    required this.candidate,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReachable = candidate.isReachable;

    return Opacity(
      opacity: isReachable ? 1.0 : 0.55,
      child: AppSettingTile(
        title: candidate.description,
        subtitle: isReachable ? '可连接' : candidate.error ?? '不可达',
        leading: Icon(
          isReachable ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 20,
          color: isReachable ? Colors.green : theme.colorScheme.error,
        ),
        trailing: isReachable
            ? const Icon(Icons.swap_horiz_rounded, size: 18)
            : null,
        onTap: onTap,
      ),
    );
  }
}
