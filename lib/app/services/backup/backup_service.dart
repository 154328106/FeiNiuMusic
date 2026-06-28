import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../db/db_constants.dart';
import '../navidrome/navidrome_source_repository.dart';
import '../playlists_service.dart';
import '../stats_service.dart';
import '../webdav/webdav_source_repository.dart';

/// Which sections of data a backup includes. Persisted so the user configures
/// it once.
class BackupSections {
  final bool playlists;
  final bool stats;
  final bool sources;
  final bool settings;

  const BackupSections({
    this.playlists = true,
    this.stats = true,
    this.sources = false,
    this.settings = false,
  });

  BackupSections copyWith({
    bool? playlists,
    bool? stats,
    bool? sources,
    bool? settings,
  }) => BackupSections(
    playlists: playlists ?? this.playlists,
    stats: stats ?? this.stats,
    sources: sources ?? this.sources,
    settings: settings ?? this.settings,
  );

  bool get any => playlists || stats || sources || settings;
}

class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const int formatVersion = 1;
  static const String webDavFolder = 'NagoMusicBackup';
  static const int maxBackupsPerDevice = 10;

  static const String _prefsSectionsKey = 'backup_sections_v1';
  static const String _prefsDeviceId = 'backup_device_id';
  static const String _prefsAutoEnabled = 'backup_auto_enabled';
  static const String _prefsAutoSourceId = 'backup_auto_source_id';
  static const String _prefsAutoIntervalH = 'backup_auto_interval_h';
  static const String _prefsAutoLastMs = 'backup_auto_last_ms';
  // Pref keys that must NOT be exported as generic "app settings".
  static const Set<String> _settingsDenyList = {
    'webdav_sources_v1',
    'navidrome_sources_v1',
    'playlists_v1',
    'debug_log_entries',
    _prefsSectionsKey,
    _prefsDeviceId,
    _prefsAutoEnabled,
    _prefsAutoSourceId,
    _prefsAutoIntervalH,
    _prefsAutoLastMs,
  };

  final PlaylistsService _playlists = PlaylistsService.instance;
  final StatsService _stats = StatsService.instance;
  final WebDavSourceRepository _webdavRepo = WebDavSourceRepository.instance;
  final NavidromeSourceRepository _navidromeRepo =
      NavidromeSourceRepository.instance;

  // ---- section preference ----
  Future<BackupSections> loadSections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsSectionsKey);
    if (raw == null) return const BackupSections();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return BackupSections(
        playlists: m['playlists'] as bool? ?? true,
        stats: m['stats'] as bool? ?? true,
        sources: m['sources'] as bool? ?? false,
        settings: m['settings'] as bool? ?? false,
      );
    } catch (_) {
      return const BackupSections();
    }
  }

  Future<void> saveSections(BackupSections s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsSectionsKey,
      jsonEncode({
        'playlists': s.playlists,
        'stats': s.stats,
        'sources': s.sources,
        'settings': s.settings,
      }),
    );
  }

  // ---- build / parse ----
  Future<String> buildBackupJson(BackupSections sections) async {
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}

    final data = <String, dynamic>{
      'format': formatVersion,
      'dbVersion': DbConstants.dbVersion,
      'appVersion': appVersion,
      'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
      'sections': {
        'playlists': sections.playlists,
        'stats': sections.stats,
        'sources': sections.sources,
        'settings': sections.settings,
      },
    };

    if (sections.playlists) {
      final all = await _playlists.loadAll();
      data['playlists'] = all.map((e) => e.toJson()).toList();
    }
    if (sections.stats) {
      data['stats'] = await _stats.exportAll();
    }
    if (sections.sources) {
      final webdav = await _webdavRepo.loadSources();
      final navidrome = await _navidromeRepo.loadSources();
      data['sources'] = {
        'webdav': webdav.map((e) => e.toJson()).toList(),
        'navidrome': navidrome.map((e) => e.toJson()).toList(),
      };
    }
    if (sections.settings) {
      data['settings'] = await _exportSettings();
    }

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Imports a backup (smart merge). Returns a short human-readable summary.
  /// [restrict] limits which sections are applied even if present in the file.
  Future<String> restoreFromJson(
    String jsonStr, {
    BackupSections? restrict,
  }) async {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('备份文件格式无效');
    }
    if (data['format'] == null) {
      throw const FormatException('不是有效的 NagoMusic 备份文件');
    }

    final applied = <String>[];

    if (data['playlists'] is List &&
        (restrict?.playlists ?? true)) {
      final n = await _importPlaylists((data['playlists'] as List));
      applied.add('歌单 $n 个');
    }
    if (data['stats'] is Map && (restrict?.stats ?? true)) {
      await _stats.importMerge((data['stats'] as Map).cast<String, dynamic>());
      applied.add('听歌统计');
    }
    if (data['sources'] is Map && (restrict?.sources ?? true)) {
      final n = await _importSources(
        (data['sources'] as Map).cast<String, dynamic>(),
      );
      applied.add('音源 $n 个');
    }
    if (data['settings'] is Map && (restrict?.settings ?? true)) {
      await _importSettings((data['settings'] as Map).cast<String, dynamic>());
      applied.add('应用设置');
    }

    return applied.isEmpty ? '没有可导入的数据' : '已导入：${applied.join('、')}';
  }

  // ---- playlists (merge by name; favorite by id; union song ids) ----
  Future<int> _importPlaylists(List raw) async {
    final existing = await _playlists.loadAll();
    final byName = <String, PlaylistEntity>{
      for (final pl in existing)
        if (!pl.isFavorite) pl.name: pl,
    };
    var count = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final entity = PlaylistEntity.fromJson(item.cast<String, dynamic>());
      final songIds = entity.songIds;
      if (entity.isFavorite ||
          entity.id == PlaylistsService.favoritePlaylistId) {
        if (songIds.isNotEmpty) {
          await _playlists.addSongs(
            PlaylistsService.favoritePlaylistId,
            songIds,
          );
        }
        continue;
      }
      final match = byName[entity.name];
      if (match != null) {
        if (songIds.isNotEmpty) {
          await _playlists.addSongs(match.id, songIds);
        }
      } else {
        final created = await _playlists.createPlaylist(entity.name);
        if (songIds.isNotEmpty) {
          await _playlists.addSongs(created.id, songIds);
        }
      }
      count++;
    }
    return count;
  }

  // ---- sources (upsert by id) ----
  Future<int> _importSources(Map<String, dynamic> data) async {
    var count = 0;
    final webdav = data['webdav'];
    if (webdav is List) {
      for (final j in webdav) {
        if (j is! Map) continue;
        await _webdavRepo.upsert(
          WebDavSource.fromJson(j.cast<String, dynamic>()),
        );
        count++;
      }
    }
    final navidrome = data['navidrome'];
    if (navidrome is List) {
      for (final j in navidrome) {
        if (j is! Map) continue;
        await _navidromeRepo.upsert(
          NavidromeSource.fromJson(j.cast<String, dynamic>()),
        );
        count++;
      }
    }
    return count;
  }

  // ---- settings (generic prefs) ----
  Future<Map<String, dynamic>> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (_settingsDenyList.contains(key)) continue;
      final value = prefs.get(key);
      if (value is bool) {
        out[key] = {'t': 'b', 'v': value};
      } else if (value is int) {
        out[key] = {'t': 'i', 'v': value};
      } else if (value is double) {
        out[key] = {'t': 'd', 'v': value};
      } else if (value is String) {
        out[key] = {'t': 's', 'v': value};
      } else if (value is List<String>) {
        out[key] = {'t': 'l', 'v': value};
      }
    }
    return out;
  }

  Future<void> _importSettings(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.entries) {
      if (_settingsDenyList.contains(entry.key)) continue;
      final v = entry.value;
      if (v is! Map) continue;
      final type = v['t'];
      final value = v['v'];
      try {
        switch (type) {
          case 'b':
            await prefs.setBool(entry.key, value as bool);
            break;
          case 'i':
            await prefs.setInt(entry.key, (value as num).toInt());
            break;
          case 'd':
            await prefs.setDouble(entry.key, (value as num).toDouble());
            break;
          case 's':
            await prefs.setString(entry.key, value as String);
            break;
          case 'l':
            await prefs.setStringList(
              entry.key,
              (value as List).map((e) => e.toString()).toList(),
            );
            break;
        }
      } catch (_) {}
    }
  }

  // ---- local file ----
  Future<String> exportToFile(BackupSections sections) async {
    final jsonStr = await buildBackupJson(sections);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'nagomusic-backup-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, name));
    await file.writeAsString(jsonStr, flush: true);
    return file.path;
  }

  /// Opens a file picker; returns the file contents or null if cancelled.
  Future<String?> pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null) return null;
    return File(path).readAsString();
  }

  // ---- WebDAV ----
  webdav.Client _client(WebDavSource source) {
    final client = webdav.newClient(
      source.endpoint.trim(),
      user: '',
      password: '',
      debug: kDebugMode,
    );
    client.setHeaders(_webdavRepo.buildHeaders(source));
    client.setConnectTimeout(15000);
    client.setSendTimeout(30000);
    client.setReceiveTimeout(30000);
    return client;
  }

  String _backupDir(WebDavSource source) {
    var base = source.path.trim();
    if (base.isEmpty) base = '/';
    if (!base.startsWith('/')) base = '/$base';
    base = base.replaceAll('\\', '/');
    if (base.length > 1 && base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base == '/' ? '/$webDavFolder' : '$base/$webDavFolder';
  }

  /// Stable per-install id so backups from different devices are distinguishable.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsDeviceId);
    if (id == null || id.isEmpty) {
      final rand = Random().nextInt(0x7fffffff).toRadixString(36);
      id = (DateTime.now().microsecondsSinceEpoch.toRadixString(36) + rand)
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (id.length > 8) id = id.substring(id.length - 8);
      await prefs.setString(_prefsDeviceId, id);
    }
    return id;
  }

  String _tsNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  DateTime? _parseTs(String ts) {
    if (ts.length != 14) return null;
    final v = int.tryParse(ts);
    if (v == null) return null;
    try {
      return DateTime(
        int.parse(ts.substring(0, 4)),
        int.parse(ts.substring(4, 6)),
        int.parse(ts.substring(6, 8)),
        int.parse(ts.substring(8, 10)),
        int.parse(ts.substring(10, 12)),
        int.parse(ts.substring(12, 14)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Uploads a timestamped, per-device backup and prunes old ones for this
  /// device. Returns the remote path written.
  Future<String> uploadToWebDav(
    WebDavSource source,
    BackupSections sections,
  ) async {
    final jsonStr = await buildBackupJson(sections);
    final client = _client(source);
    final dir = _backupDir(source);
    try {
      await client.mkdirAll(dir);
    } catch (_) {}
    final dev = await deviceId();
    final path = '$dir/nagomusic_backup__${dev}__${_tsNow()}.json';
    await client.write(path, Uint8List.fromList(utf8.encode(jsonStr)));
    await _pruneWebDav(client, dir, dev, keep: maxBackupsPerDevice);
    return path;
  }

  Future<List<WebDavBackupEntry>> listWebDavBackups(WebDavSource source) async {
    final client = _client(source);
    final dir = _backupDir(source);
    List<webdav.File> files;
    try {
      files = await client.readDir(dir);
    } catch (_) {
      return [];
    }
    final me = await deviceId();
    final list = <WebDavBackupEntry>[];
    for (final f in files) {
      if ((f.isDir ?? false)) continue;
      final name = f.name ?? '';
      if (!name.startsWith('nagomusic_backup') || !name.endsWith('.json')) {
        continue;
      }
      String? dev;
      DateTime? ts;
      final core = name.substring(0, name.length - 5);
      final parts = core.split('__');
      if (parts.length >= 3) {
        dev = parts[1];
        ts = _parseTs(parts[2]);
      }
      list.add(
        WebDavBackupEntry(
          name: name,
          path: f.path ?? '$dir/$name',
          sizeBytes: f.size ?? 0,
          modified: f.mTime ?? ts,
          deviceId: dev,
          isCurrentDevice: dev != null && dev == me,
        ),
      );
    }
    list.sort((a, b) {
      final am = a.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bm = b.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bm.compareTo(am);
    });
    return list;
  }

  Future<String> downloadFromWebDavPath(
    WebDavSource source,
    String path,
  ) async {
    final client = _client(source);
    final bytes = await client.read(path);
    return utf8.decode(bytes);
  }

  Future<void> _pruneWebDav(
    webdav.Client client,
    String dir,
    String deviceId, {
    required int keep,
  }) async {
    try {
      final files = await client.readDir(dir);
      final mine =
          files.where((f) {
            final n = f.name ?? '';
            return !(f.isDir ?? false) &&
                n.startsWith('nagomusic_backup__${deviceId}__') &&
                n.endsWith('.json');
          }).toList()..sort((a, b) {
            final am = a.mTime ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bm = b.mTime ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bm.compareTo(am);
          });
      for (var i = keep; i < mine.length; i++) {
        final path = mine[i].path;
        if (path != null) {
          try {
            await client.remove(path);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<List<WebDavSource>> webDavSources() => _webdavRepo.loadSources();

  // ---- auto backup config ----
  Future<AutoBackupConfig> loadAutoConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return AutoBackupConfig(
      enabled: prefs.getBool(_prefsAutoEnabled) ?? false,
      sourceId: prefs.getString(_prefsAutoSourceId) ?? '',
      intervalHours: prefs.getInt(_prefsAutoIntervalH) ?? 24,
    );
  }

  Future<void> setAutoEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoEnabled, v);
  }

  Future<void> setAutoSourceId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsAutoSourceId, id);
  }

  Future<void> setAutoIntervalHours(int h) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsAutoIntervalH, h);
  }

  static bool hasRunAutoBackupThisSession = false;

  /// Called on app launch. Uploads to WebDAV if auto-backup is enabled and the
  /// minimum interval has elapsed. Silent on failure.
  Future<void> maybeAutoBackupOnLaunch() async {
    if (hasRunAutoBackupThisSession) return;
    hasRunAutoBackupThisSession = true;
    final cfg = await loadAutoConfig();
    if (!cfg.enabled) return;
    final sections = await loadSections();
    if (!sections.any) return;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(_prefsAutoLastMs) ?? 0;
    if (now - last < cfg.intervalHours * 3600 * 1000) return;
    final sources = await webDavSources();
    if (sources.isEmpty) return;
    WebDavSource target = sources.firstWhere(
      (s) => s.id == cfg.sourceId,
      orElse: () => sources.first,
    );
    try {
      await uploadToWebDav(target, sections);
      await prefs.setInt(_prefsAutoLastMs, now);
    } catch (_) {}
  }
}

class WebDavBackupEntry {
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime? modified;
  final String? deviceId;
  final bool isCurrentDevice;

  const WebDavBackupEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.deviceId,
    required this.isCurrentDevice,
  });
}

class AutoBackupConfig {
  final bool enabled;
  final String sourceId;
  final int intervalHours;

  const AutoBackupConfig({
    required this.enabled,
    required this.sourceId,
    required this.intervalHours,
  });
}
