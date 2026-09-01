import 'package:flutter/material.dart';

/// 列表行里的「VIP」小角标。
///
/// 只是提示这首歌在源站需要会员，**不代表放不了** —— 配了第三方音源时
/// VIP 歌照样能播。所以做得克制：描边小标签，不抢歌名。
class VipBadge extends StatelessWidget {
  const VipBadge({super.key, this.fontSize = 9});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 金色系而不是主题色：和「正在播放」之类的状态色区分开。
    const gold = Color(0xFFD4A017);
    final color = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFE8C25A)
        : gold;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.8), width: 0.8),
        borderRadius: BorderRadius.circular(3),
        color: color.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.14 : 0.10,
        ),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          fontSize: fontSize,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: color,
        ),
      ),
    );
  }
}
