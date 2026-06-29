import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nagomusic/app/services/backup/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupTarget serialization', () {
    test('toJson/fromJson round-trips', () {
      const t = BackupTarget(sourceId: 'webdav-1', path: '/backups/nago');
      final restored = BackupTarget.fromJson(t.toJson());
      expect(restored.sourceId, t.sourceId);
      expect(restored.path, t.path);
    });

    test('fromJson falls back to default path when missing', () {
      final t = BackupTarget.fromJson({'sourceId': 'webdav-1'});
      expect(t.path, BackupService.defaultBackupPath);
    });
  });

  group('BackupService targets', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('addTarget normalizes the path', () async {
      await BackupService.instance.saveTargets(const []);
      await BackupService.instance.addTarget(
        const BackupTarget(sourceId: 'webdav-1', path: 'backups\\sub\\'),
      );
      final list = await BackupService.instance.loadTargets();
      expect(list, hasLength(1));
      expect(list.first.path, '/backups/sub');
    });

    test('empty path normalizes to the default backup path', () async {
      await BackupService.instance.saveTargets(const []);
      await BackupService.instance.addTarget(
        const BackupTarget(sourceId: 'webdav-1', path: '   '),
      );
      final list = await BackupService.instance.loadTargets();
      expect(list.first.path, BackupService.defaultBackupPath);
    });

    test('migrates legacy auto-source id into a single target', () async {
      SharedPreferences.setMockInitialValues({
        'backup_auto_source_id': 'webdav-legacy',
      });
      final list = await BackupService.instance.loadTargets();
      expect(list, hasLength(1));
      expect(list.first.sourceId, 'webdav-legacy');
      expect(list.first.path, BackupService.defaultBackupPath);
    });

    test('removeTargetAt drops the right entry', () async {
      await BackupService.instance.saveTargets(const [
        BackupTarget(sourceId: 'a', path: '/a'),
        BackupTarget(sourceId: 'b', path: '/b'),
      ]);
      await BackupService.instance.removeTargetAt(0);
      final list = await BackupService.instance.loadTargets();
      expect(list, hasLength(1));
      expect(list.first.sourceId, 'b');
    });
  });
}
