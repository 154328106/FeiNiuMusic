import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final String latestVersion;
  final String? releaseName;
  final String? releaseUrl;
  final String? releaseNotes;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseName,
    this.releaseUrl,
    this.releaseNotes,
  });
}

class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static const String releasePageUrl =
      'https://github.com/Keduoli03/NagoMusic/releases/latest';
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/Keduoli03/NagoMusic/releases/latest';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  String? _cachedVersion;

  /// The running app's version (e.g. "1.3.0-beta+1"), read from the platform.
  Future<String> currentVersion() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      final v = build.isEmpty ? info.version : '${info.version}+$build';
      _cachedVersion = v;
      return v;
    } catch (_) {
      return _cachedVersion ?? '0.0.0';
    }
  }

  Future<AppUpdateInfo> checkLatest(String currentVersion) async {
    final response = await _dio.get<Map<String, dynamic>>(latestReleaseApiUrl);
    final data = response.data ?? <String, dynamic>{};
    final tag = (data['tag_name'] as String? ?? '').trim();
    final name = (data['name'] as String?)?.trim();
    final url = (data['html_url'] as String?)?.trim();
    final body = (data['body'] as String?)?.trim();
    final latest = tag.isEmpty ? currentVersion : _normalizeVersion(tag);
    return AppUpdateInfo(
      latestVersion: latest,
      releaseName: name == null || name.isEmpty ? null : name,
      releaseUrl: url == null || url.isEmpty ? releasePageUrl : url,
      releaseNotes: body == null || body.isEmpty ? null : body,
      hasUpdate: _compareVersions(latest, currentVersion) > 0,
    );
  }

  String _normalizeVersion(String version) {
    final value = version.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      return value.substring(1);
    }
    return value;
  }

  int _compareVersions(String a, String b) {
    final left = _normalizeVersion(a).split(RegExp(r'[.+-]'));
    final right = _normalizeVersion(b).split(RegExp(r'[.+-]'));
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final l = i < left.length ? int.tryParse(left[i]) ?? 0 : 0;
      final r = i < right.length ? int.tryParse(right[i]) ?? 0 : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }
}
