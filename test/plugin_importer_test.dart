import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/plugin/plugin_importer.dart';
import 'package:feiniu_music/app/services/plugin/plugin_manifest.dart';

/// 构造一个最小可用插件 zip（单个插件，含 manifest + source.js + lib）。
List<int> _buildPluginZip({
  String id = 'com.example.test',
  String name = '测试插件',
  Map<String, dynamic>? manifestExtra,
  List<String> entryLines = const [
    'function searchSongs(request) { return []; }',
  ],
}) {
  final manifest = <String, dynamic>{
    'id': id,
    'name': name,
    'versionCode': 1,
    'versionName': '1.0.0',
    'author': 'Test',
    'description': 'Test plugin',
    'apiVersion': 4,
    'minHostApiVersion': 3,
    'entry': 'source.js',
    'includeDirs': ['lib'],
    'capabilities': ['searchSongs', 'getLyrics', 'searchCovers'],
    ...?manifestExtra,
  };
  final archive = Archive();
  archive.addFile(ArchiveFile.string(
    '$id/manifest.json',
    jsonEncode(manifest),
  ));
  archive.addFile(ArchiveFile.string(
    '$id/source.js',
    entryLines.join('\n'),
  ));
  archive.addFile(ArchiveFile.string(
    '$id/lib/01_http.js',
    '// helper\nfunction helper() { return 1; }\n',
  ));
  return ZipEncoder().encode(archive);
}

void main() {
  group('PluginImporter.inspectZip', () {
    test('识别单个插件：manifest 正确解析', () {
      final importer = PluginImporter();
      final candidates = importer.inspectZip(
        _buildPluginZip(),
      );
      expect(candidates.length, 1);
      final candidate = candidates.single;
      expect(candidate.manifest.id, 'com.example.test');
      expect(candidate.manifest.name, '测试插件');
      expect(candidate.manifest.apiVersion, 4);
      expect(candidate.manifest.capabilities, {
        PluginCapability.searchSongs,
        PluginCapability.getLyrics,
        PluginCapability.searchCovers,
      });
      expect(candidate.rootInArchive, 'com.example.test');
    });

    test('入口缺失 → 抛异常', () {
      final importer = PluginImporter();
      // 覆盖默认 entryLines 为空 source.js（manifest 指向不存在的文件）
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
        'com.example.test/manifest.json',
        jsonEncode({
          'id': 'com.example.test',
          'name': '测试',
          'versionCode': 1,
          'versionName': '1.0.0',
          'apiVersion': 4,
          'entry': 'source.js',
        }),
      ));
      final bytes = ZipEncoder().encode(archive);
      expect(
        () => importer.inspectZip(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('zip 内无 manifest → 抛异常', () {
      final importer = PluginImporter();
      final archive = Archive();
      archive.addFile(ArchiveFile.string('readme.txt', 'hello'));
      final bytes = ZipEncoder().encode(archive);
      expect(
        () => importer.inspectZip(bytes),
        throwsA(predicate((e) =>
            e is FormatException && e.message.contains('manifest.json'))),
      );
    });

    test('非法插件 id → 抛异常', () {
      final importer = PluginImporter();
      expect(
        () => importer.inspectZip(
          _buildPluginZip(
            manifestExtra: {'id': 'not-a-valid-id'},
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('路径穿越条目 → 抛异常', () {
      final importer = PluginImporter();
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
        'com.example.test/manifest.json',
        jsonEncode({
          'id': 'com.example.test',
          'name': '测试',
          'versionCode': 1,
          'versionName': '1.0.0',
          'apiVersion': 4,
          'entry': 'source.js',
        }),
      ));
      archive.addFile(ArchiveFile.string(
        '../evil.txt',
        'evil',
      ));
      final bytes = ZipEncoder().encode(archive);
      expect(
        () => importer.inspectZip(bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PluginImporter.extractPlugin', () {
    test('解压到目标目录：manifest + entry + include 均落盘', () async {
      final importer = PluginImporter();
      final tempDir = await Directory.systemTemp.createTemp('plugin_test_');
      final destDir = '${tempDir.path}/com.example.test';

      await importer.extractPlugin(
        _buildPluginZip(),
        'com.example.test',
        destDir,
      );

      final manifestFile = '$destDir/manifest.json';
      expect(
        await File(manifestFile).exists(),
        true,
        reason: 'manifest.json 应解压',
      );
      expect(
        await File('$destDir/source.js').exists(),
        true,
        reason: 'source.js 应解压',
      );
      expect(
        await File('$destDir/lib/01_http.js').exists(),
        true,
        reason: 'lib/01_http.js 应解压',
      );

      await tempDir.delete(recursive: true);
    });
  });

  group('PluginManifest.fromJson', () {
    test('configFields 解析', () {
      final manifest = PluginManifest.fromJson({
        'id': 'com.example.test',
        'name': '测试',
        'versionCode': 1,
        'versionName': '1.0.0',
        'apiVersion': 4,
        'configFields': [
          {
            'key': 'cover_size',
            'title': '封面尺寸',
            'type': 'dropdown',
            'defaultValue': '1200',
            'options': [
              {'value': '600', 'label': '600'},
              {'value': '1200', 'label': '1200'},
            ],
          },
          {
            'key': 'enable_x',
            'title': '启用 X',
            'type': 'switch',
          },
        ],
      });
      expect(manifest.configFields.length, 2);
      expect(manifest.configFields[0].key, 'cover_size');
      expect(manifest.configFields[0].type, PluginConfigFieldType.dropdown);
      expect(manifest.configFields[0].options.length, 2);
      expect(manifest.configFields[1].type, PluginConfigFieldType.switchField);
    });

    test('空 capabilities → 归一化为 searchSongs', () {
      final manifest = PluginManifest.fromJson({
        'id': 'com.example.test',
        'name': '测试',
        'versionCode': 1,
        'versionName': '1.0.0',
        'apiVersion': 4,
      });
      expect(manifest.normalizedCapabilities, {PluginCapability.searchSongs});
    });
  });
}
