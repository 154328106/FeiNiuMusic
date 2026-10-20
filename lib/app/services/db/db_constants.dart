class DbConstants {
  static const String dbName = 'feiniu_music.db';
  static const int dbVersion = 18;
  static const String tableSongs = 'songs';
  // v18：本地下载表（跨源，存重建 SongEntity 所需的 songJson + 本地路径/来源/音质）。
  static const String tableDownloads = 'downloads';
  static const String tablePlaylists = 'playlists';
  static const String tablePlaylistSongs = 'playlist_songs';
  static const String tableListeningDays = 'listening_days';
  static const String tableSongStats = 'song_stats';
  static const String tableAlbumStats = 'album_stats';
  static const String tablePlaylistStats = 'playlist_stats';
  static const String tableApiCache = 'api_cache';
  static const String tableReportEvents = 'report_events';
}
