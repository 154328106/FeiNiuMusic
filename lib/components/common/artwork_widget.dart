import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/state/song_state.dart';

class ArtworkWidget extends StatefulWidget {
  final SongEntity song;
  final double size;
  final double borderRadius;
  final Widget? placeholder;
  final bool preferOriginal;
  final bool keepPreviousUntilLoaded;

  const ArtworkWidget({
    super.key,
    required this.song,
    required this.size,
    required this.borderRadius,
    this.placeholder,
    this.preferOriginal = false,
    this.keepPreviousUntilLoaded = false,
  });

  @override
  State<ArtworkWidget> createState() => _ArtworkWidgetState();
}

class _ArtworkWidgetState extends State<ArtworkWidget> with SignalsMixin {
  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverId = widget.song.coverId;
    final size = widget.size;
    final borderRadius = widget.borderRadius;

    final placeholder =
        widget.placeholder ??
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        );

    Widget child;
    if (coverId != null && coverId.isNotEmpty) {
      final requestSize = widget.preferOriginal ? 800 : 120;
      final coverUrl =
          FeiNiuApiClient.instance.coverUrl(
            coverId,
            size: requestSize,
            updatedAt: widget.song.updatedAt,
          );
      child = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: CachedNetworkImage(
          imageUrl: coverUrl,
          httpHeaders: _authHeaders(),
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (context, url) => SizedBox(
            width: size,
            height: size,
            child: Center(
              child: SizedBox(
                width: size * 0.35,
                height: size * 0.35,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (context, url, error) => placeholder,
        ),
      );
    } else {
      child = placeholder;
    }

    return SizedBox(width: size, height: size, child: child);
  }
}
