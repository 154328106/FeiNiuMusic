import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/account_entry.dart';
import '../../app/services/feiniu/account_store.dart';

/// 账号展示卡片（侧边栏与「我的」页共用）
///
/// 显示当前账号：登录用户名，仅一行。服务器名称/FNID 由侧边栏顶部头部
/// （[SideMenu._buildHeader]）或「我的」页展示。点击进入账号切换页。
/// 无当前账号时渲染为空。
class AccountHeaderCard extends StatelessWidget {
  const AccountHeaderCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AccountStore.instance.currentAccountId,
      builder: (context, accountId, _) {
        final account = AccountStore.instance.currentAccount;
        if (account == null) return const SizedBox.shrink();
        return _AccountHeaderCardInner(account: account);
      },
    );
  }
}

class _AccountHeaderCardInner extends StatelessWidget {
  final AccountEntry account;

  const _AccountHeaderCardInner({required this.account});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.accounts),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primary.withValues(alpha: 0.16),
                child: Text(
                  account.username.isNotEmpty
                      ? account.username.characters.first
                      : '?',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  account.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
