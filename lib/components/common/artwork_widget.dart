import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../app/services/artwork_service.dart';
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
  final ArtworkService _artworkService = ArtworkService.instance;

  late final _bytes = createSignal<Uint8List?>(null);
  late final _loading = createSignal(false);

  @override
  void initState() {
    super.initState();
    _tryLoad();
  }

  @override
  void didUpdateWidget(covariant ArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.localCoverPath != widget.song.localCoverPath ||
        oldWidget.song.uri != widget.song.uri ||
        oldWidget.preferOriginal != widget.preferOriginal ||
        oldWidget.keepPreviousUntilLoaded != widget.keepPreviousUntilLoaded) {
      if (!widget.keepPreviousUntilLoaded) {
        _bytes.value = null;
      }
      _loading.value = false;
      _tryLoad();
    }
  }

  Future<void> _tryLoad() async {
    _loading.value = true;
    final bytes = await _artworkService.loadArtworkBytes(
      uri: widget.song.uri,
      localCoverPath: widget.song.localCoverPath,
      localAssetId: widget.song.localAssetId,
      isLocal: widget.song.isLocal,
      preferOriginal: widget.preferOriginal,
    );
    if (!mounted) return;
    if (bytes != null && bytes.isNotEmpty) {
      _bytes.value = bytes;
    } else if (!widget.keepPreviousUntilLoaded) {
      _bytes.value = null;
    }
    _loading.value = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cachedPath = widget.song.localCoverPath;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (widget.size * dpr).round();
    // Decode at the display's pixel size even for preferOriginal: a 3000px cover
    // shown in a ~400px box otherwise decodes at full native resolution and
    // wastes memory/decode time. size*dpr is the true full quality for the view.
    final cacheWidth = cacheSize > 0 ? cacheSize : null;
    final cacheHeight = cacheWidth;
    final placeholder =
        widget.placeholder ??
        Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );

    return Watch.builder(
      builder: (context) {
        Widget child;
        final bytes = _bytes.value;
        final isLoading = _loading.value;
        if (widget.preferOriginal && bytes != null && bytes.isNotEmpty) {
          child = ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
            ),
          );
        } else if (cachedPath != null && cachedPath.trim().isNotEmpty) {
          child = ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Image.file(
              File(cachedPath),
              width: widget.size,
              height: widget.size,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
            ),
          );
        } else if (bytes != null && bytes.isNotEmpty) {
          child = ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
            ),
          );
        } else if (isLoading) {
          child = SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(
              child: SizedBox(
                width: widget.size * 0.35,
                height: widget.size * 0.35,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        } else {
          child = placeholder;
        }

        return SizedBox(width: widget.size, height: widget.size, child: child);
      },
    );
  }
}
