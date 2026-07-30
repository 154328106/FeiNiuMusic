import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/library/library_detail_pages.dart';

void main() {
  SongEntity song(
    String id, {
    required String title,
    int? discNumber,
    int? trackNumber,
  }) {
    return SongEntity(
      id: id,
      title: title,
      artist: 'Artist',
      album: 'Album',
      uri: 'file:///$id.mp3',
      isLocal: true,
      discNumber: discNumber,
      trackNumber: trackNumber,
    );
  }

  test('album detail defaults to disc and track order', () {
    final songs = [
      song('disc-2-track-1', title: 'C', discNumber: 2, trackNumber: 1),
      song('track-2', title: 'B', trackNumber: 2),
      song('track-1', title: 'A', trackNumber: 1),
    ];

    final sorted = sortAlbumDetailSongs(
      songs,
      sortKey: 'trackNumber',
      ascending: true,
    );

    expect(sorted.map((item) => item.id), [
      'track-1',
      'track-2',
      'disc-2-track-1',
    ]);
  });

  test('songs without a track number sort after numbered songs', () {
    final songs = [
      song('unknown-z', title: 'Z'),
      song('track-2', title: 'B', trackNumber: 2),
      song('unknown-a', title: 'A'),
    ];

    final sorted = sortAlbumDetailSongs(
      songs,
      sortKey: 'trackNumber',
      ascending: true,
    );

    expect(sorted.map((item) => item.id), [
      'track-2',
      'unknown-a',
      'unknown-z',
    ]);
  });
}
