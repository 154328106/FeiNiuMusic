import 'package:flutter_test/flutter_test.dart';
import 'package:nagomusic/app/state/song_state.dart';
import 'package:nagomusic/pages/home/home_recommender.dart';

void main() {
  test('cold-start discovery modes use distinct stable fallback sequences', () {
    final songs = List.generate(
      12,
      (index) => SongEntity(
        id: 'song-$index',
        title: 'Song $index',
        artist: 'Artist ${index % 4}',
        album: 'Album ${index % 3}',
        uri: 'file:///song-$index.mp3',
        isLocal: true,
      ),
    );
    final now = DateTime(2026, 7, 20, 12);
    HomeRecommender createRecommender() => HomeRecommender(
      now: now,
      playCounts: const {},
      lastPlayedMs: const {},
      favoriteIds: const {},
    );

    final recommender = createRecommender();
    final daily = recommender.daily(songs, limit: 6);
    final heart = recommender.heart(songs, limit: 6);
    final recommended = recommender.recommended(songs, limit: 6);

    expect(heart.map((song) => song.id), isNot(daily.map((song) => song.id)));
    expect(
      recommended.map((song) => song.id),
      isNot(daily.map((song) => song.id)),
    );
    expect(
      recommended.map((song) => song.id),
      isNot(heart.map((song) => song.id)),
    );

    final next = createRecommender();
    expect(
      next.heart(songs, limit: 6).map((song) => song.id),
      heart.map((song) => song.id),
    );
    expect(
      next.recommended(songs, limit: 6).map((song) => song.id),
      recommended.map((song) => song.id),
    );
  });
}
