import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/transcode_service.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 构造一个用拦截器短路返回指定响应体的 Dio（不真正发网络请求）。
///
/// [respond] 返回任意响应体：JSON Map（transcode 响应）。
Dio _mockDio(
  dynamic Function(RequestOptions options) respond, {
  DioException Function(RequestOptions options)? error,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final e = error?.call(options);
        if (e != null) {
          handler.reject(e, true);
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: respond(options),
          ),
        );
      },
    ),
  );
  return dio;
}

SongEntity _song(String id, {String? format}) {
  return SongEntity(id: id, title: 't', artist: '[{"name":"a"}]', format: format);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeiNiuTranscodeService.instance.resetForTest();
    FeiNiuApiClient.instance.setDioForTest(
      _mockDio((o) => {
        'code': 0,
        'data': {
          'audioSpec': {'format': 'dsf'},
          'track': {
            'audioSpec': {'format': 'dsf'},
          },
          'url': '/music/api/v1/track/hls/id-1/preset.m3u8',
        },
      }),
    );
  });

  group('isTranscodeNeeded', () {
    test('不支持的格式返回 true', () {
      for (final f in ['dsf', 'dff', 'wma', 'ape', 'dts', 'aiff', 'DSF', ' Wma ']) {
        expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(f), isTrue,
            reason: '$f 应判定为需要转码');
      }
    });

    test('常见格式返回 false', () {
      for (final f in ['flac', 'mp3', 'ogg', 'wav', 'm4a', 'aac', 'opus']) {
        expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(f), isFalse,
            reason: '$f 应判定为无需转码');
      }
    });

    test('null/空返回 false', () {
      expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(null), isFalse);
      expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(''), isFalse);
    });
  });

  group('isMediaKitFormat', () {
    test('黑名单格式返回 true', () {
      for (final f in ['dsf', 'DSF', 'ape', 'wma', 'dts', 'aiff']) {
        expect(FeiNiuTranscodeService.isMediaKitFormat(f), isTrue,
            reason: '$f 应交给 media_kit');
      }
    });

    test('FLAC 与常见格式返回 false（just_audio 直连）', () {
      for (final f in ['flac', 'FLAC', 'mp3', 'ogg', 'wav', 'm4a', 'aac', 'opus']) {
        expect(FeiNiuTranscodeService.isMediaKitFormat(f), isFalse,
            reason: '$f 应留在 just_audio');
      }
    });
  });

  group('isMediaKitCodec', () {
    test('风险 codec 返回 true（EAC3/AC3/ALAC/环绕）', () {
      for (final c in ['eac3', 'EAC3', 'ac3', 'alac', 'dts', 'truehd', 'mlp']) {
        expect(FeiNiuTranscodeService.isMediaKitCodec(c), isTrue,
            reason: '$c 应交给 media_kit（FFmpeg）');
      }
    });

    test('常见 codec 返回 false（系统解码器可处理）', () {
      for (final c in ['aac', 'mp3', 'flac', 'opus', 'vorbis']) {
        expect(FeiNiuTranscodeService.isMediaKitCodec(c), isFalse,
            reason: '$c 应留在 just_audio');
      }
    });

    test('null/空返回 false', () {
      expect(FeiNiuTranscodeService.isMediaKitCodec(null), isFalse);
      expect(FeiNiuTranscodeService.isMediaKitCodec(''), isFalse);
    });
  });

  group('isRiskySilenceContainer', () {
    test('可能内嵌风险 codec 的容器返回 true', () {
      for (final f in ['m4a', 'M4A', 'm4b', 'mp4', 'aac', 'mka', 'mkv']) {
        expect(FeiNiuTranscodeService.isRiskySilenceContainer(f), isTrue,
            reason: '$f 可能需要无声看门狗');
      }
    });

    test('普通容器返回 false', () {
      for (final f in ['flac', 'mp3', 'ogg', 'wav', 'opus', 'dsf']) {
        expect(FeiNiuTranscodeService.isRiskySilenceContainer(f), isFalse,
            reason: '$f 无需看门狗');
      }
    });

    test('null/空返回 false', () {
      expect(FeiNiuTranscodeService.isRiskySilenceContainer(null), isFalse);
      expect(FeiNiuTranscodeService.isRiskySilenceContainer(''), isFalse);
    });
  });

  group('hlsUrlForFlac', () {
    test('metadata 确认是 dsf → 请求转码并返回绝对 URL（FLAC）', () async {
      final api = FeiNiuApiClient.instance;
      final meta = await api.trackMetadata('id-1');
      expect(meta, isNotNull);
      expect(meta!['audioSpec'], isNotNull);

      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-1', format: 'dsf'),
      );
      expect(url, isNotNull);
    });

    test('普通 FLAC → null（just_audio 直连，不走转码）', () async {
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-2', format: 'flac'),
      );
      expect(url, isNull);
    });

    test('force=true 时普通 FLAC 也强制转码（升级 media_kit）', () async {
      String? requestedCodec;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final data = o.data as Map<String, dynamic>;
            final output = data['output'] as Map<String, dynamic>;
            requestedCodec = output['codec'] as String?;
          }
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'flac'},
              'url': '/music/api/v1/track/hls/id-2/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-2', format: 'flac'),
        force: true,
      );
      expect(url, 'https://nas.example.com/music/api/v1/track/hls/id-2/preset.m3u8');
      expect(requestedCodec, 'flac');
    });

    test('非 media_kit 格式（mp3）→ null，不调用网络', () async {
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-2', format: 'mp3'),
      );
      expect(url, isNull);
    });

    test('song.format 为空 → 经 metadata 确认 dsf 后仍转码', () async {
      var metadataCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('metadata')) metadataCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-2a/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-2a', format: ''), // 列表接口未返回 audioSpec
      );
      expect(url, 'https://nas.example.com/music/api/v1/track/hls/id-2a/preset.m3u8');
      expect(metadataCalls, 1);
    });

    test('metadata 失败（格式无法确认）→ 返回 null，不转码', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) => DioException(requestOptions: o, type: DioExceptionType.connectionError),
        ),
      );
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-2b', format: ''),
      );
      expect(url, isNull);
    });

    test('转码成功 → 缓存命中，第二次不重复请求', () async {
      var transcodeCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) transcodeCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-4/preset.m3u8',
            },
          };
        }),
      );

      final first = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-4', format: 'dsf'),
      );
      final second = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-4', format: 'dsf'),
      );
      expect(first, second);
      expect(transcodeCalls, 1, reason: '第二次应命中 TTL 缓存');
    });

    test('invalidate 后重新请求转码', () async {
      var transcodeCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) transcodeCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-5/preset.m3u8',
            },
          };
        }),
      );

      await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-5', format: 'dsf'),
      );
      FeiNiuTranscodeService.instance.invalidate('id-5');
      await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-5', format: 'dsf'),
      );
      expect(transcodeCalls, 2, reason: 'invalidate 后应重新请求');
    });

    test('trackTranscode 返回 null → hlsUrlForFlac 返回 null', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) => {
          'code': 0,
          'data': {
            'audioSpec': {'format': 'dsf'},
          },
        }),
      );
      final url = await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-6', format: 'dsf'),
      );
      expect(url, isNull);
    });

    test('默认请求 FLAC 转码（无损优先）', () async {
      String? requestedCodec;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final data = o.data as Map<String, dynamic>;
            final output = data['output'] as Map<String, dynamic>;
            requestedCodec = output['codec'] as String?;
          }
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-8/preset.m3u8',
            },
          };
        }),
      );
      await FeiNiuTranscodeService.instance.hlsUrlForFlac(
        _song('id-8', format: 'dsf'),
      );
      expect(requestedCodec, 'flac', reason: '默认应请求无损 FLAC');
    });

    test('网络异常 → 抛 DioException（调用方回退直连）', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) => DioException(requestOptions: o, type: DioExceptionType.connectionError),
        ),
      );
      expect(
        () => FeiNiuTranscodeService.instance.hlsUrlForFlac(
          _song('id-7', format: 'dsf'),
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('resolveHlsUrl：相对路径拼接 baseUrl，绝对路径原样', () async {
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
      final api = FeiNiuApiClient.instance;
      expect(
        api.resolveHlsUrl('/music/api/v1/track/hls/x/preset.m3u8'),
        'https://nas.example.com/music/api/v1/track/hls/x/preset.m3u8',
      );
      expect(
        api.resolveHlsUrl('https://cdn.example.com/a.m3u8'),
        'https://cdn.example.com/a.m3u8',
      );
    });
  });

  group('resolvedCodecFor', () {
    test('song.codec 非空 → 直接返回，不请求 metadata', () async {
      var metadataCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('metadata')) metadataCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'codec': 'eac3', 'format': 'm4a'},
            },
          };
        }),
      );
      final song = SongEntity(
        id: 'id-c1',
        title: 't',
        artist: '[{"name":"a"}]',
        format: 'm4a',
        codec: 'aac',
      );
      expect(await FeiNiuTranscodeService.instance.resolvedCodecFor(song), 'aac');
      expect(metadataCalls, 0, reason: 'song.codec 已有值不应请求网络');
    });

    test('song.codec 为空 → 经 metadata 解析 codec 并返回', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) => {
          'code': 0,
          'data': {
            'audioSpec': {'codec': 'eac3', 'format': 'm4a'},
          },
        }),
      );
      final song = _song('id-c2', format: 'm4a'); // codec 为空
      expect(
        await FeiNiuTranscodeService.instance.resolvedCodecFor(song),
        'eac3',
      );
    });

    test('codec 经缓存命中，第二次不重复请求 metadata', () async {
      var metadataCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('metadata')) metadataCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'codec': 'alac', 'format': 'm4a'},
            },
          };
        }),
      );
      final song = _song('id-c3', format: 'm4a');
      final first = await FeiNiuTranscodeService.instance.resolvedCodecFor(song);
      final second = await FeiNiuTranscodeService.instance.resolvedCodecFor(song);
      expect(first, 'alac');
      expect(second, 'alac');
      expect(metadataCalls, 1, reason: '第二次应命中会话缓存');
    });

    test('metadata 失败 → 返回 null', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) =>
              DioException(requestOptions: o, type: DioExceptionType.connectionError),
        ),
      );
      final song = _song('id-c4', format: 'm4a');
      expect(await FeiNiuTranscodeService.instance.resolvedCodecFor(song), isNull);
    });

    test('format/codec 共享一次 metadata：先查 codec 后查 format 只请求一次', () async {
      var metadataCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('metadata')) metadataCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'codec': 'eac3', 'format': 'm4a'},
            },
          };
        }),
      );
      final song = _song('id-c5', format: ''); // 两者都空
      final codec = await FeiNiuTranscodeService.instance.resolvedCodecFor(song);
      final format = await FeiNiuTranscodeService.instance.resolvedFormatFor(song);
      expect(codec, 'eac3');
      expect(format, 'm4a');
      expect(metadataCalls, 1, reason: 'codec+format 应共享同一次 metadata 请求');
    });
  });
}
