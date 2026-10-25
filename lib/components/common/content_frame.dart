import 'package:flutter/material.dart';

import '../../app/state/settings_background_state.dart';
import '../../app/state/settings_surface_state.dart';

/// 列表区块的「加框」方式。
enum AppContentFrameStyle {
  /// 不加框，保持原样。
  none,

  /// 整块描边：一圈圆角描边把整个列表框起来，行之间用内缩分隔线。
  outlined,

  /// 逐行卡片：每一行各自是一张圆角卡片，行与行之间留空隙。
  cards;

  String get label => switch (this) {
    AppContentFrameStyle.none => '不加框',
    AppContentFrameStyle.outlined => '整块描边',
    AppContentFrameStyle.cards => '逐行卡片',
  };

  String get description => switch (this) {
    AppContentFrameStyle.none => '列表直接贴在背景上',
    AppContentFrameStyle.outlined => '整个列表套一圈圆角描边',
    AppContentFrameStyle.cards => '每首歌单独一张圆角卡片',
  };

  static AppContentFrameStyle fromName(String? raw) =>
      AppContentFrameStyle.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => AppContentFrameStyle.none,
      );
}

/// 描边色：统一走「边框与底色」那套样式；没开加框返回 null。
///
/// [accent] 是卡片自己的色相（没自定义描边色时用），alpha 0.3 × 默认描边深浅
/// 0.5 ≈ 原来内容框默认的 0.15。
Color? _unitFrameColor(
  BuildContext context, {
  Color? accent,
  double scale = 1.0,
}) {
  final c = SurfacePaint.frameColor(
    context,
    AppSurfaceSettings.contentStyle,
    fallback: accent?.withValues(alpha: 0.3),
  );
  return c?.withValues(alpha: (c.a * scale).clamp(0.0, 1.0));
}

/// 逐行卡片 / 独立卡片的底色。
Color _cardFill(BuildContext context) =>
    SurfacePaint.fill(context, AppSurfaceSettings.contentStyle);

/// 卡片投影：按「厚度」走，比底栏轻一半（列表一大片，用底栏那么重会糊）。
List<BoxShadow> _cardShadow(BuildContext context) =>
    SurfacePaint.shadow(context, AppSurfaceSettings.contentStyle, scale: 0.5);

/// 独立单元（首页「最近播放 / 本地收藏」这类卡）用的底色和投影：加框时和
/// 列表卡片一样吃「框里面的底色 / 框内深浅 / 框内厚度」，不加框时返回 null /
/// 空，调用方照原样画。
Color? appUnitFill(BuildContext context) =>
    AppBackgroundSettings.contentFrameStyle.value == AppContentFrameStyle.none
    ? null
    : _cardFill(context);

List<BoxShadow> appUnitShadow(BuildContext context) =>
    AppBackgroundSettings.contentFrameStyle.value == AppContentFrameStyle.none
    ? const []
    : _cardShadow(context);

Color _frameBorderColor(BuildContext context, {double scale = 1.0}) =>
    _unitFrameColor(context, scale: scale) ?? Colors.transparent;

/// 样式一改就重建，否则改完要重进页面才生效。
Widget _watchFrameSettings(BuildContext context, WidgetBuilder builder) {
  return ListenableBuilder(
    listenable: AppSurfaceSettings.style,
    builder: (context, _) => builder(context),
  );
}

/// 首页那些**独立单元**（四宫格、快捷入口卡、漫游卡）共用的描边。
///
/// 这些卡原本各自写死 `Border.all(accent…)`，和列表那套可调的框各走各的 ——
/// 统一走这里：画不画、什么颜色、多透明，全听「边框与底色」。
///
/// [accent] 是这张卡自己的色相，没自定义颜色时用它，保持原来的观感。
/// 返回 null 表示当前是「不加框」——调用方别画。
BoxBorder? appUnitBorder(
  BuildContext context, {
  Color? accent,
  double scale = 1.0,
}) {
  final style = AppBackgroundSettings.contentFrameStyle.value;
  if (style == AppContentFrameStyle.none) return null;
  final c = _unitFrameColor(context, accent: accent, scale: scale);
  return c == null
      ? null
      : Border.all(
          color: c,
          width: SurfacePaint.frameWidth(AppSurfaceSettings.contentStyle),
        );
}

/// 同 [appUnitBorder]，但只给颜色 —— 有些组件（如 GlassPanel）只收
/// `borderColor`，自己去 `Border.all`。
///
/// 「不加框」时返回透明色而不是 null：null 在那些组件里会退回它们各自的
/// 默认描边，等于这个设置对它们无效。
Color appUnitBorderColor(
  BuildContext context, {
  Color? accent,
  double scale = 1.0,
}) {
  final style = AppBackgroundSettings.contentFrameStyle.value;
  if (style == AppContentFrameStyle.none) return Colors.transparent;
  return _unitFrameColor(context, accent: accent, scale: scale) ??
      Colors.transparent;
}

/// 让用了 [appUnitBorder] 的单元跟着框设置一起重建。
///
/// 不套它的话，改完样式要重进页面才生效。
class AppUnitFrameBuilder extends StatelessWidget {
  const AppUnitFrameBuilder({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppBackgroundSettings.contentFrameStyle,
        AppSurfaceSettings.style,
      ]),
      builder: (context, _) => builder(context),
    );
  }
}

/// 列表区块的外框。仅在「整块描边」样式下生效。
///
/// 其余样式**原样透传**子组件，不额外包一层 widget —— 没开这个效果的用户
/// 不该平白多一层布局开销。
class AppContentFrame extends StatelessWidget {
  final Widget child;
  final double borderRadius;

  /// 子树是不是「每一行自己会用 [AppContentRow] 出卡片」的列表。
  ///
  /// 是的话，「逐行卡片」模式下这里必须**不画**——否则一堆行卡片外面再套一个
  /// 大框，成了双层。「整块描边」模式下仍然要画，那正是它的用途。
  final bool wrapsRows;

  const AppContentFrame({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.wrapsRows = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppContentFrameStyle>(
      valueListenable: AppBackgroundSettings.contentFrameStyle,
      builder: (context, style, child) {
        if (style == AppContentFrameStyle.none) return child!;
        if (style == AppContentFrameStyle.cards && wrapsRows) return child!;
        return _watchFrameSettings(context, (context) {
          // 「逐行卡片」下，独立区块（漫游卡、快捷入口）也要有卡片外观 ——
          // 它们不是列表行，走不到 AppContentRow，只靠这里出框。
          final isCards = style == AppContentFrameStyle.cards;
          return Container(
            decoration: BoxDecoration(
              color: isCards ? _cardFill(context) : null,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: _frameBorderColor(context, scale: isCards ? 0.75 : 1.0),
                width: SurfacePaint.frameWidth(AppSurfaceSettings.contentStyle),
              ),
              boxShadow: _cardShadow(context),
            ),
            // 描边是圆角的，内容也要跟着裁，否则行的点击高亮会顶出圆角。
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius - 1.2),
              child: child,
            ),
          );
        });
      },
      child: child,
    );
  }
}

/// 列表中单行的外观。
///
/// - 「逐行卡片」：包成一张圆角卡片（浅底 + 描边 + 轻投影）；
/// - 「整块描边」：行本身不加装饰，但除最后一行外补一条**内缩**分隔线
///   （顶到边会和外框的圆角打架）；
/// - 「不加框」：原样透传。
class AppContentRow extends StatelessWidget {
  final Widget child;

  /// 是否是所在列表的最后一行（决定要不要画分隔线 / 留底部间距）。
  final bool isLast;

  /// 卡片内的横向内缩。行本身没有横向 padding 时（如歌曲页的
  /// `_SongListTile`），不留这个内缩封面会直接贴到卡片描边上。
  final double horizontalInset;

  const AppContentRow({
    super.key,
    required this.child,
    this.isLast = false,
    this.horizontalInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppContentFrameStyle>(
      valueListenable: AppBackgroundSettings.contentFrameStyle,
      builder: (context, style, child) {
        if (style == AppContentFrameStyle.none) return child!;
        return _watchFrameSettings(context, (context) {
          switch (style) {
            case AppContentFrameStyle.none:
              return child!;
            case AppContentFrameStyle.outlined:
              if (isLast) return child!;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  child!,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      // 分隔线比外框淡一档，不然一列横线太抢眼。
                      color: _frameBorderColor(context, scale: 0.6),
                    ),
                  ),
                ],
              );
            case AppContentFrameStyle.cards:
              return Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: _cardFill(context),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _frameBorderColor(context, scale: 0.75),
                      width: SurfacePaint.frameWidth(
                        AppSurfaceSettings.contentStyle,
                      ),
                    ),
                    boxShadow: _cardShadow(context),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalInset,
                      ),
                      child: child,
                    ),
                  ),
                ),
              );
          }
        });
      },
      child: child,
    );
  }
}
