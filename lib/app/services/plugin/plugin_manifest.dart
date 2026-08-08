import 'dart:convert';

/// 数据源插件 manifest（Lyrico 插件格式，见 Lyrico docs/plugins/manifest.md）。
///
/// 由插件 zip 内 `manifest.json` 解析，描述插件身份、入口脚本、能力与配置项。
class PluginManifest {
  final String id;
  final String name;
  final int versionCode;
  final String versionName;
  final String author;
  final String description;
  final int apiVersion;
  final int minHostApiVersion;
  final String entry;
  final List<String> includeDirs;
  final String? icon;
  final Set<PluginCapability> capabilities;
  final List<PluginConfigField> configFields;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.versionCode,
    required this.versionName,
    this.author = '',
    this.description = '',
    required this.apiVersion,
    this.minHostApiVersion = 1,
    this.entry = 'source.js',
    this.includeDirs = const [],
    this.icon,
    this.capabilities = const {},
    this.configFields = const [],
  });

  /// 未声明能力时按「仅支持 searchSongs」处理（Lyrico 兼容旧插件）。
  Set<PluginCapability> get normalizedCapabilities =>
      capabilities.isEmpty ? {PluginCapability.searchSongs} : capabilities;

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    return PluginManifest(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: json['versionName'] as String? ?? '',
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
      minHostApiVersion: (json['minHostApiVersion'] as num?)?.toInt() ?? 1,
      entry: json['entry'] as String? ?? 'source.js',
      includeDirs: (json['includeDirs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      icon: json['icon'] as String?,
      capabilities: (json['capabilities'] as List?)
              ?.map((e) => PluginCapability.tryParse(e.toString()))
              .whereType<PluginCapability>()
              .toSet() ??
          const {},
      configFields: (json['configFields'] as List?)
              ?.map((e) => PluginConfigField.fromJson(
                  e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'versionCode': versionCode,
        'versionName': versionName,
        'author': author,
        'description': description,
        'apiVersion': apiVersion,
        'minHostApiVersion': minHostApiVersion,
        'entry': entry,
        'includeDirs': includeDirs,
        'icon': icon,
        'capabilities': capabilities.map((c) => c.name).toList(),
        'configFields': configFields.map((c) => c.toJson()).toList(),
      };

  @override
  String toString() => 'PluginManifest($id $versionName)';
}

/// 插件能力。
enum PluginCapability {
  searchSongs,
  getLyrics,
  searchCovers;

  static PluginCapability? tryParse(String value) {
    for (final c in PluginCapability.values) {
      if (c.name == value) return c;
    }
    return null;
  }
}

/// 插件配置项（configFields 声明式生成配置界面）。
class PluginConfigField {
  final String key;
  final String title;
  final String? summary;
  final String group;
  final PluginConfigFieldType type;
  final bool required;
  final String defaultValue;
  final List<PluginConfigOption> options;

  const PluginConfigField({
    required this.key,
    required this.title,
    this.summary,
    this.group = '',
    required this.type,
    this.required = false,
    this.defaultValue = '',
    this.options = const [],
  });

  factory PluginConfigField.fromJson(Map<String, dynamic> json) {
    return PluginConfigField(
      key: json['key'] as String? ?? '',
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String?,
      group: json['group'] as String? ?? '',
      type: PluginConfigFieldType.tryParse(json['type']?.toString()),
      required: json['required'] as bool? ?? false,
      defaultValue: json['defaultValue']?.toString() ?? '',
      options: (json['options'] as List?)
              ?.map((e) => PluginConfigOption.fromJson(
                  e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'summary': summary,
        'group': group,
        'type': type.name,
        'required': required,
        'defaultValue': defaultValue,
        'options': options.map((o) => o.toJson()).toList(),
      };
}

enum PluginConfigFieldType {
  text,
  password,
  number,
  switchField,
  dropdown,
  textarea,
  markdown;

  static PluginConfigFieldType tryParse(String? value) {
    switch (value) {
      case 'text':
        return PluginConfigFieldType.text;
      case 'password':
        return PluginConfigFieldType.password;
      case 'number':
        return PluginConfigFieldType.number;
      case 'switch':
        return PluginConfigFieldType.switchField;
      case 'dropdown':
        return PluginConfigFieldType.dropdown;
      case 'textarea':
        return PluginConfigFieldType.textarea;
      case 'markdown':
        return PluginConfigFieldType.markdown;
      default:
        return PluginConfigFieldType.text;
    }
  }
}

class PluginConfigOption {
  final String value;
  final String label;
  final String summary;

  const PluginConfigOption({
    required this.value,
    required this.label,
    this.summary = '',
  });

  factory PluginConfigOption.fromJson(Map<String, dynamic> json) {
    return PluginConfigOption(
      value: json['value']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() =>
      {'value': value, 'label': label, 'summary': summary};
}

/// 已安装插件（manifest + 运行状态）。
class InstalledPlugin {
  final PluginManifest manifest;
  final String dirPath;

  /// 各类能力的启用状态（Lyrico 支持按能力分 Tab 开关）。
  bool enabled;
  bool metadataEnabled;
  bool lyricsEnabled;
  bool coverEnabled;

  /// 用户配置（configFields 填写值，key → value 字符串）。
  Map<String, String> config;

  /// 排序权重（越小越靠前，数据源维护页拖动排序用）。
  int sortOrder;

  InstalledPlugin({
    required this.manifest,
    required this.dirPath,
    this.enabled = true,
    this.metadataEnabled = true,
    this.lyricsEnabled = true,
    this.coverEnabled = true,
    this.config = const {},
    this.sortOrder = 0,
  });

  factory InstalledPlugin.fromJson(Map<String, dynamic> json) {
    return InstalledPlugin(
      manifest: PluginManifest.fromJson(
        jsonDecode(json['manifest'] as String? ?? '{}') as Map<String, dynamic>,
      ),
      dirPath: json['dirPath'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      metadataEnabled: json['metadataEnabled'] as bool? ?? true,
      lyricsEnabled: json['lyricsEnabled'] as bool? ?? true,
      coverEnabled: json['coverEnabled'] as bool? ?? true,
      config: (json['config'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v.toString())) ??
          const {},
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'manifest': jsonEncode(manifest.toJson()),
        'dirPath': dirPath,
        'enabled': enabled,
        'metadataEnabled': metadataEnabled,
        'lyricsEnabled': lyricsEnabled,
        'coverEnabled': coverEnabled,
        'config': config,
        'sortOrder': sortOrder,
      };

  bool hasCapability(PluginCapability cap) => normalizedCapabilities.contains(cap);

  Set<PluginCapability> get normalizedCapabilities =>
      manifest.normalizedCapabilities;
}
