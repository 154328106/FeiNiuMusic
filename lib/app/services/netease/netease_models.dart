/// 网易云音乐的数据模型。
///
/// 只覆盖最小闭环（搜索 / 播放 / 歌词）需要的字段；网易云同一个实体在不同
/// 接口里字段名不一样（搜索结果用 `ar`/`al`/`dt`，歌单详情用
/// `artists`/`album`/`duration`），解析时两套都认。
library;

class NetEaseSong {
  const NetEaseSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.coverUrl,
    required this.durationMs,
    required this.fee,
  });

  final int id;
  final String name;

  /// 多位歌手用 ` / ` 连接后的显示名。
  final String artists;
  final String album;
  final String? coverUrl;
  final int durationMs;

  /// 付费标记：0 免费、1 VIP、4 付费单曲、8 免费/翻唱资源。
  final int fee;

  /// VIP / 付费单曲（列表角标用）。8 是免费资源，不算 VIP。
  bool get isVip => fee == 1 || fee == 4;

  static NetEaseSong? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int) return null;

    final artistList =
        (json['artists'] as List?) ?? (json['ar'] as List?) ?? const [];
    final artists = artistList
        .whereType<Map>()
        .map((e) => e['name'])
        .whereType<String>()
        .where((n) => n.isNotEmpty)
        .join(' / ');

    // album（歌单详情）与 al（搜索结果）二选一，封面字段也不同。
    String albumName = '';
    String? cover;
    final albumJson = (json['album'] as Map?) ?? (json['al'] as Map?);
    if (albumJson != null) {
      albumName = albumJson['name'] as String? ?? '';
      final pic =
          albumJson['picUrl'] as String? ?? albumJson['blurPicUrl'] as String?;
      if (pic != null && pic.isNotEmpty) cover = pic;
    }

    final durationMs =
        (json['duration'] as int?) ?? (json['dt'] as int?) ?? 0;

    return NetEaseSong(
      id: id,
      name: json['name'] as String? ?? '',
      artists: artists,
      album: albumName,
      coverUrl: cover,
      durationMs: durationMs,
      fee: (json['fee'] as int?) ?? 0,
    );
  }
}

/// 歌曲播放地址查询结果。
class NetEaseSongUrl {
  const NetEaseSongUrl({
    required this.id,
    required this.url,
    required this.freeTrial,
    required this.bitrate,
    required this.type,
  });

  final int id;

  /// 播放直链；灰色歌曲 / 无版权时为 null。
  final String? url;

  /// 服务端只给了试听片段（VIP 歌曲未登录或非会员）。
  final bool freeTrial;
  final int? bitrate;

  /// 音频容器格式（mp3 / flac …）。
  final String? type;
}

/// 登录账号信息。
class NetEaseUser {
  const NetEaseUser({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
  });

  final int userId;
  final String nickname;
  final String? avatarUrl;

  static NetEaseUser? fromJson(Map<String, dynamic> json) {
    final id = json['userId'];
    if (id is! int) return null;
    return NetEaseUser(
      userId: id,
      nickname: json['nickname'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String?,
    );
  }
}

/// 扫码登录轮询状态。
///
/// 网易云用 HTTP 200 + body 里的 code 表达扫码进度，不是 HTTP 状态码。
enum NetEaseQrStatus {
  /// 800：二维码已过期，需要重新获取。
  expired,

  /// 801：等待扫码。
  waiting,

  /// 802：已扫码，等待手机端确认。
  scanned,

  /// 803：确认登录成功（此时响应的 Set-Cookie 里带 MUSIC_U）。
  authorized,

  /// 其它未知返回码。
  unknown;

  static NetEaseQrStatus fromCode(int code) => switch (code) {
    800 => NetEaseQrStatus.expired,
    801 => NetEaseQrStatus.waiting,
    802 => NetEaseQrStatus.scanned,
    803 => NetEaseQrStatus.authorized,
    _ => NetEaseQrStatus.unknown,
  };
}
