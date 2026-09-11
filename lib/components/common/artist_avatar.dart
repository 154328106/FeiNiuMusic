import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/artist_image_service.dart';

/// 歌手头像，按「真人照片 → 库里的歌手图 → 首字母」依次回退。
///
/// 飞牛 NAS 的 `artist.coverId` 是拿该歌手某张专辑的封面充数的，所以不换源
/// 的话整个歌手列表都是专辑封面。这里先去 QQ 找真人照片
/// （[ArtistImageService]，只认名字完全对得上的），找不到再用库里那张。
///
/// 照片是异步查的：先画回退图，查到了再换上。所以不会因为取头像卡住列表
/// 滚动，也不会有一格一格的空白。
class ArtistAvatar extends StatefulWidget {
  /// 库里的歌手图地址（多半是专辑封面），没有就传 null。
  final String? fallbackUrl;

  /// 取 [fallbackUrl] 要带的鉴权头。
  final Map<String, String>? fallbackHeaders;

  /// 前两级都没有时垫在最底下的，比如代表作封面。null 则显示首字母。
  final Widget? placeholder;

  final String name;
  final double size;

  const ArtistAvatar({
    super.key,
    required this.name,
    required this.size,
    this.fallbackUrl,
    this.fallbackHeaders,
    this.placeholder,
  });

  @override
  State<ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<ArtistAvatar> {
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ArtistAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用 State：名字换了就得重查，否则滚动时头像会串到上一个歌手。
    if (oldWidget.name != widget.name) {
      _photoUrl = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final name = widget.name;
    final url = await ArtistImageService.instance.photoUrl(name);
    if (!mounted || url == null) return;
    // 等回来的时候这一格可能已经复用给别的歌手了，对不上就丢掉。
    if (widget.name != name) return;
    setState(() => _photoUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.size / 2;
    final photo = _photoUrl;
    if (photo != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(photo),
      );
    }

    final fallback = widget.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(
          fallback,
          headers: widget.fallbackHeaders,
        ),
      );
    }

    final initial = widget.name.isNotEmpty ? widget.name.characters.first : '?';
    return widget.placeholder ??
        CircleAvatar(radius: radius, child: Text(initial));
  }
}
