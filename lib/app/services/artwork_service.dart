import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';

import 'native_audio_thumbnail_service.dart';
import 'http_utils.dart';
import 'metadata/ogg_vorbis_comment.dart';

class ArtworkService {
  ArtworkService._();

  static final ArtworkService instance = ArtworkService._();

  static const bool _debugArtwork = false;
  // Compressed bytes cache — a typical 320px JPEG thumb is ~15–30 KB, so 400
  // entries sits around ~10 MB. Well below the decoded ImageCache budget and
  // large enough that scroll-back through a full album grid doesn't churn.
  static const int _maxCache = 400;
  static const int _maxConcurrent = 6;

  final LinkedHashMap<String, Uint8List?> _bytesCache =
      LinkedHashMap<String, Uint8List?>();
  final Map<String, Future<Uint8List?>> _loadingFutures =
      <String, Future<Uint8List?>>{};
  final Map<String, String?> _assetIdCache = <String, String?>{};
  final Map<String, Future<String?>> _assetIdFutures =
      <String, Future<String?>>{};
  final List<_ArtworkRequest> _queue = <_ArtworkRequest>[];
  int _active = 0;

  String _normalizePath(String path) => path.replaceAll('\\', '/').trim();

  Future<String?> resolveLocalAssetId(String? uri) async {
    final trimmedUri = _normalizePath(uri ?? '');
    if (trimmedUri.isEmpty) return null;
    if (_assetIdCache.containsKey(trimmedUri)) {
      if (kDebugMode && _debugArtwork) {
        debugPrint(
          '[ArtworkService] resolveLocalAssetId cache uri=$trimmedUri asset=${_assetIdCache[trimmedUri]}',
        );
      }
      return _assetIdCache[trimmedUri];
    }
    final inflight = _assetIdFutures[trimmedUri];
    if (inflight != null) return inflight;
    final future = _resolveLocalAssetIdInternal(trimmedUri);
    _assetIdFutures[trimmedUri] = future;
    final resolved = await future;
    _assetIdFutures.remove(trimmedUri);
    _assetIdCache[trimmedUri] = resolved;
    if (kDebugMode && _debugArtwork) {
      debugPrint(
        '[ArtworkService] resolveLocalAssetId result uri=$trimmedUri asset=$resolved',
      );
    }
    return resolved;
  }

  Future<Uint8List?> loadArtworkBytes({
    required String? uri,
    required String? localCoverPath,
    required String? localAssetId,
    required bool isLocal,
    required bool preferOriginal,
  }) async {
    final trimmedCover = (localCoverPath ?? '').trim();
    if (!preferOriginal && trimmedCover.isNotEmpty) {
      final file = File(trimmedCover);
      if (await file.exists()) {
        if (kDebugMode && _debugArtwork) {
          debugPrint(
            '[ArtworkService] loadArtworkBytes local cache exists uri=${uri ?? ''} cover=$trimmedCover',
          );
        }
        return null;
      }
    }

    if (!isLocal) return null;
    final trimmedUri = (uri ?? '').trim();
    var trimmedAssetId = (localAssetId ?? '').trim();
    if (trimmedUri.isEmpty) return null;

    if (kDebugMode && _debugArtwork) {
      debugPrint(
        '[ArtworkService] loadArtworkBytes request uri=$trimmedUri asset=$trimmedAssetId preferOriginal=$preferOriginal isLocal=$isLocal',
      );
    }

    final cacheBase = trimmedAssetId.isNotEmpty
        ? 'asset:$trimmedAssetId'
        : trimmedUri;
    final cacheKey = preferOriginal ? '$cacheBase|original' : cacheBase;
    if (_bytesCache.containsKey(cacheKey)) {
      final cached = _bytesCache.remove(cacheKey);
      _bytesCache[cacheKey] = cached;
      if (kDebugMode && _debugArtwork) {
        debugPrint('[ArtworkService] loadArtworkBytes memory key=$cacheKey');
      }
      return cached;
    }

    final inflight = _loadingFutures[cacheKey];
    if (inflight != null) return inflight;

    final completer = Completer<Uint8List?>();
    _loadingFutures[cacheKey] = completer.future;
    _queue.add(
      _ArtworkRequest(
        trimmedUri,
        trimmedAssetId,
        cacheKey,
        preferOriginal,
        completer,
      ),
    );
    _drainQueue();

    return completer.future.whenComplete(() {
      _loadingFutures.remove(cacheKey);
    });
  }

  Future<String?> _resolveLocalAssetIdInternal(String normalizedUri) async {
    try {
      final ps = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.audio,
            mediaLocation: false,
          ),
        ),
      );
      if (!ps.isAuth) return null;

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.audio,
      );
      final seenIds = <String>{};
      const pageSize = 200;
      for (final album in albums) {
        final count = await album.assetCountAsync;
        var start = 0;
        while (start < count) {
          final end = (start + pageSize).clamp(0, count);
          final entities = await album.getAssetListRange(
            start: start,
            end: end,
          );
          if (entities.isEmpty) break;
          for (final entity in entities) {
            if (!seenIds.add(entity.id)) continue;
            final file = await entity.file;
            if (file == null) continue;
            if (_normalizePath(file.path) == normalizedUri) {
              if (kDebugMode && _debugArtwork) {
                debugPrint(
                  '[ArtworkService] resolveLocalAssetId matched uri=$normalizedUri asset=${entity.id}',
                );
              }
              return entity.id;
            }
          }
          start = end;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void clearByUri(String? uri) {
    final trimmed = (uri ?? '').trim();
    if (trimmed.isEmpty) return;
    _bytesCache.remove(trimmed);
    _bytesCache.remove('$trimmed|original');
  }

  void _remember(String cacheKey, Uint8List? bytes) {
    _bytesCache.remove(cacheKey);
    _bytesCache[cacheKey] = bytes;
    while (_bytesCache.length > _maxCache) {
      _bytesCache.remove(_bytesCache.keys.first);
    }
  }

  void _drainQueue() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeLast();
      _active += 1;
      _readArtworkBytes(
            task.uri,
            assetId: task.assetId,
            preferOriginal: task.preferOriginal,
          )
          .then((bytes) {
            _remember(task.cacheKey, bytes);
            if (!task.completer.isCompleted) {
              task.completer.complete(bytes);
            }
          })
          .catchError((_) {
            _remember(task.cacheKey, null);
            if (!task.completer.isCompleted) {
              task.completer.complete(null);
            }
          })
          .whenComplete(() {
            _active -= 1;
            _drainQueue();
          });
    }
  }

  static Future<Uint8List?> _readArtworkBytes(
    String uri, {
    required String assetId,
    required bool preferOriginal,
  }) async {
    try {
      if (!preferOriginal) {
        final nativeThumb = await NativeAudioThumbnailService.instance
            .loadThumbnail(uri, size: 320);
        if (nativeThumb != null && nativeThumb.isNotEmpty) {
          if (kDebugMode && _debugArtwork) {
            debugPrint(
              '[ArtworkService] native platform thumb uri=$uri bytes=${nativeThumb.length}',
            );
          }
          return nativeThumb;
        }
      }

      if (assetId.isNotEmpty && !preferOriginal) {
        final entity = await AssetEntity.fromId(assetId);
        if (entity != null) {
          final thumb = await entity.thumbnailDataWithSize(
            const ThumbnailSize(320, 320),
          );
          if (thumb != null && thumb.isNotEmpty) {
            if (kDebugMode && _debugArtwork) {
              debugPrint(
                '[ArtworkService] native thumb uri=$uri asset=$assetId bytes=${thumb.length}',
              );
            }
            return thumb;
          }
          if (kDebugMode && _debugArtwork) {
            debugPrint(
              '[ArtworkService] native thumb empty uri=${HttpUtils.redactUrl(uri)} asset=$assetId',
            );
          }
        } else if (kDebugMode && _debugArtwork) {
          debugPrint(
            '[ArtworkService] asset missing uri=${HttpUtils.redactUrl(uri)} asset=$assetId',
          );
        }
      }

      final file = File(uri);
      if (!await file.exists()) return null;
      final metadata = readMetadata(file, getImage: true);
      var original = metadata.pictures.isNotEmpty
          ? metadata.pictures.first.bytes
          : Uint8List(0);
      // The bundled reader misses OGG/Opus covers (METADATA_BLOCK_PICTURE in a
      // Vorbis comment) — fall back to our own extractor for those.
      if (original.isEmpty && isOggPath(uri)) {
        final ogg = extractOggVorbisComments(uri, includeArtwork: true);
        final oggArt = ogg?.artwork;
        if (oggArt != null && oggArt.isNotEmpty) {
          original = oggArt;
        }
      }
      if (original.isEmpty) return null;
      if (kDebugMode && _debugArtwork) {
        debugPrint(
          '[ArtworkService] embedded art uri=$uri bytes=${original.length} preferOriginal=$preferOriginal',
        );
      }
      if (preferOriginal) {
        return original;
      }
      try {
        final compressed = await FlutterImageCompress.compressWithList(
          original,
          minWidth: 300,
          minHeight: 300,
          quality: 85,
        );
        if (compressed.isNotEmpty) {
          return compressed;
        }
      } catch (_) {}
      return original;
    } catch (_) {
      if (kDebugMode && _debugArtwork) {
        debugPrint(
          '[ArtworkService] read artwork failed uri=$uri asset=$assetId',
        );
      }
      return null;
    }
  }
}

class _ArtworkRequest {
  final String uri;
  final String assetId;
  final String cacheKey;
  final bool preferOriginal;
  final Completer<Uint8List?> completer;

  _ArtworkRequest(
    this.uri,
    this.assetId,
    this.cacheKey,
    this.preferOriginal,
    this.completer,
  );
}
