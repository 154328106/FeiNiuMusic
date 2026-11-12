import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player_service.dart';

/// 2026-11-12：弱网优化。播放器报的错以前不分类，全掉进「通用恢复」分支，
/// 那个分支会 `forceRefresh` 重新解析地址 —— 对在线歌等于把整条解灰链再跑
/// 一遍（最坏 10 秒），对 NAS 歌等于丢掉已经下了一半的 `.part`。
///
/// 现在网络抖动走「原地重连」，解码失败/地址失效才重新解析。这两类的处理
/// 方式相反，分错了代价很大，所以把分类逻辑钉在这里。
void main() {
  group('网络抖动 → 原地重连', () {
    test('Dart 侧的失速超时与连接错误', () {
      expect(
        PlayerService.isTransientNetworkError(
          'TimeoutException after 0:00:20.000000',
        ),
        isTrue,
      );
      expect(
        PlayerService.isTransientNetworkError(
          "SocketException: Connection reset by peer",
        ),
        isTrue,
      );
    });

    test('ExoPlayer 侧的网络异常', () {
      expect(
        PlayerService.isTransientNetworkError(
          'com.google.android.exoplayer2.upstream.HttpDataSource'
          r'$HttpDataSourceException: Unable to connect',
        ),
        isTrue,
      );
      expect(
        PlayerService.isTransientNetworkError(
          'java.net.UnknownHostException: Unable to resolve host',
        ),
        isTrue,
      );
      expect(
        PlayerService.isTransientNetworkError(
          'java.net.SocketTimeoutException: timeout',
        ),
        isTrue,
      );
    });

    test('纯 5xx 不算抖动：服务器答复了，说明连接是通的', () {
      // 刻意如此。5xx 代表「连上了，但那边给不了这个资源」，这时**重新解析**
      // 去换一个 CDN/音源比原地重连更可能解决问题；而弱网真正会撞上的是
      // 超时/连接重置/DNS 失败，不是 5xx。
      expect(
        PlayerService.isTransientNetworkError(
          'InvalidResponseCodeException: Response code: 503',
        ),
        isFalse,
      );
    });
  });

  group('4xx → 必须重新解析，不能原地重连', () {
    test('403：临时直链过期，重连多少次都没用', () {
      expect(
        PlayerService.isTransientNetworkError(
          'com.google.android.exoplayer2.upstream.HttpDataSource'
          r'$InvalidResponseCodeException: Response code: 403',
        ),
        isFalse,
        reason: '虽然消息里含 HttpDataSource，但 4xx 必须优先判定',
      );
    });

    test('404：歌被下架', () {
      expect(
        PlayerService.isTransientNetworkError('Response code: 404'),
        isFalse,
      );
    });

    test('我们自己缓存源抛的 HTTP Status Error 4xx', () {
      expect(
        PlayerService.isTransientNetworkError('HTTP Status Error: 410'),
        isFalse,
      );
    });
  });

  group('解码类错误不算网络', () {
    test('FLAC 帧超限 / 系统解码器失败照旧走各自分支', () {
      expect(
        PlayerService.isTransientNetworkError(
          'InsufficientCapacityException: Buffer too small',
        ),
        isFalse,
      );
      expect(
        PlayerService.isTransientNetworkError(
          'MediaCodecAudioRenderer error, CodecException',
        ),
        isFalse,
      );
      expect(
        PlayerService.isTransientNetworkError('Error decoding audio'),
        isFalse,
      );
    });

    test('空消息不崩', () {
      expect(PlayerService.isTransientNetworkError(''), isFalse);
    });
  });
}
