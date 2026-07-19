class SongEntity {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? uri;
  final bool isLocal;
  final String? headersJson;
  final int? durationMs;
  final int? bitrate;
  final int? sampleRate;
  final int? fileSize;
  final String? format;
  final String? sourceId;
  final int? fileModifiedMs;
  final String? localCoverPath;
  final String? localAssetId;
  final bool tagsParsed;
  // Track/disc numbers pulled from ID3/Vorbis/M4A tags at scan time. Optional
  // because plenty of loose singles / re-encodes carry no track metadata.
  final int? trackNumber;
  final int? discNumber;

  const SongEntity({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.uri,
    required this.isLocal,
    this.headersJson,
    this.durationMs,
    this.bitrate,
    this.sampleRate,
    this.fileSize,
    this.format,
    this.sourceId,
    this.fileModifiedMs,
    this.localCoverPath,
    this.localAssetId,
    this.tagsParsed = false,
    this.trackNumber,
    this.discNumber,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'uri': uri,
      'isLocal': isLocal ? 1 : 0,
      'headersJson': headersJson,
      'durationMs': durationMs,
      'bitrate': bitrate,
      'sampleRate': sampleRate,
      'fileSize': fileSize,
      'format': format,
      'sourceId': sourceId,
      'fileModifiedMs': fileModifiedMs,
      'localCoverPath': localCoverPath,
      'localAssetId': localAssetId,
      'tagsParsed': tagsParsed ? 1 : 0,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
    };
  }

  factory SongEntity.fromMap(Map<String, dynamic> map) {
    int? parseInt(dynamic v) {
      if (v is int) return v;
      return int.tryParse(v?.toString() ?? '');
    }

    return SongEntity(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '未知标题').toString(),
      artist: (map['artist'] ?? '未知艺术家').toString(),
      album: map['album']?.toString(),
      uri: map['uri']?.toString(),
      isLocal: map['isLocal'] == true || map['isLocal'] == 1,
      headersJson: map['headersJson']?.toString(),
      durationMs: parseInt(map['durationMs']),
      bitrate: parseInt(map['bitrate']),
      sampleRate: parseInt(map['sampleRate']),
      fileSize: parseInt(map['fileSize']),
      format: map['format']?.toString(),
      sourceId: map['sourceId']?.toString(),
      fileModifiedMs: parseInt(map['fileModifiedMs']),
      localCoverPath: map['localCoverPath']?.toString(),
      localAssetId: map['localAssetId']?.toString(),
      tagsParsed: map['tagsParsed'] == true || map['tagsParsed'] == 1,
      trackNumber: parseInt(map['trackNumber']),
      discNumber: parseInt(map['discNumber']),
    );
  }

  SongEntity copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? uri,
    bool? isLocal,
    String? headersJson,
    int? durationMs,
    int? bitrate,
    int? sampleRate,
    int? fileSize,
    String? format,
    String? sourceId,
    int? fileModifiedMs,
    String? localCoverPath,
    String? localAssetId,
    bool? tagsParsed,
    int? trackNumber,
    int? discNumber,
  }) {
    return SongEntity(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      uri: uri ?? this.uri,
      isLocal: isLocal ?? this.isLocal,
      headersJson: headersJson ?? this.headersJson,
      durationMs: durationMs ?? this.durationMs,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      fileSize: fileSize ?? this.fileSize,
      format: format ?? this.format,
      sourceId: sourceId ?? this.sourceId,
      fileModifiedMs: fileModifiedMs ?? this.fileModifiedMs,
      localCoverPath: localCoverPath ?? this.localCoverPath,
      localAssetId: localAssetId ?? this.localAssetId,
      tagsParsed: tagsParsed ?? this.tagsParsed,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
    );
  }
}
