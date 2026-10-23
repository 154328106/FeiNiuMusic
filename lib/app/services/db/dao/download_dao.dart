import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../db_constants.dart';
import '../db_helper.dart';
import '../../../state/song_source.dart';
import '../../../state/song_state.dart';

/// 一条本地下载记录：歌曲实体 + 本地文件路径 + 来源/音质/大小/时间。
///
/// songJson 存整条 [SongEntity.toMap]，重建时 [SongEntity.fromMap] 还原，
/// 避免下载表列随 songs 表迁移漂移。
class DownloadRecord {
  const DownloadRecord({
    required this.song,
    required this.localPath,
    required this.source,
    required this.quality,
    required this.fileSize,
    required this.downloadedAt,
  });

  final SongEntity song;
  final String localPath;
  final SongSource source;

  /// 下载时选的档位标签（如「无损」「最佳可得」），仅用于展示。
  final String quality;
  final int fileSize;
  final int downloadedAt;

  Map<String, Object?> toRow() => {
    'id': song.id,
    'songJson': jsonEncode(song.toMap()),
    'localPath': localPath,
    'source': source.name,
    'quality': quality,
    'fileSize': fileSize,
    'downloadedAt': downloadedAt,
  };

  static DownloadRecord fromRow(Map<String, Object?> row) {
    final map = jsonDecode(row['songJson'] as String) as Map<String, dynamic>;
    return DownloadRecord(
      song: SongEntity.fromMap(map),
      localPath: row['localPath'] as String,
      source: SongSource.values.firstWhere(
        (s) => s.name == row['source'],
        orElse: () => SongSource.fromSongId(row['id'] as String),
      ),
      quality: (row['quality'] as String?) ?? '',
      fileSize: (row['fileSize'] as int?) ?? 0,
      downloadedAt: (row['downloadedAt'] as int?) ?? 0,
    );
  }
}

class DownloadDao {
  static final DownloadDao instance = DownloadDao._();
  DownloadDao._();

  Future<void> upsert(DownloadRecord record) async {
    final db = await DbHelper.instance.database;
    await db.insert(
      DbConstants.tableDownloads,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 全部下载记录，最新下载在前。
  Future<List<DownloadRecord>> all() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableDownloads,
      orderBy: 'downloadedAt DESC',
    );
    return rows.map(DownloadRecord.fromRow).toList();
  }

  /// 仅取 `id → localPath` 映射，供播放热路径同步命中本地文件用。
  Future<Map<String, String>> idToPath() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableDownloads,
      columns: ['id', 'localPath'],
    );
    return {
      for (final row in rows) row['id'] as String: row['localPath'] as String,
    };
  }

  Future<DownloadRecord?> get(String id) async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableDownloads,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DownloadRecord.fromRow(rows.first);
  }

  Future<void> delete(String id) async {
    final db = await DbHelper.instance.database;
    await db.delete(
      DbConstants.tableDownloads,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 仅更新本地路径（迁移下载目录时用）。
  Future<void> updatePath(String id, String localPath) async {
    final db = await DbHelper.instance.database;
    await db.update(
      DbConstants.tableDownloads,
      {'localPath': localPath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
