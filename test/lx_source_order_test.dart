import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/lxscript/lx_source_manager.dart';

/// 2026-11-05：脚本多了要能调顺序（取址按列表从上往下问）。
/// 脚本都设成未启用，载入时不会起 JS 引擎。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object> index(List<String> ids) => {
    'lx_sources_index': jsonEncode([
      for (final id in ids)
        {
          'id': id,
          'name': '脚本$id',
          'enabled': false,
          'sources': ['kg'],
        },
    ]),
  };

  List<String> order() =>
      LxSourceManager.instance.list().map((m) => m.id).toList();

  Future<void> reset(List<String> ids) async {
    SharedPreferences.setMockInitialValues(index(ids));
    await LxSourceManager.instance.reloadFromStorage();
  }

  test('下移 / 上移 / 移到最前', () async {
    await reset(['a', 'b', 'c']);
    expect(order(), ['a', 'b', 'c']);

    await LxSourceManager.instance.move('a', 1); // 下移
    expect(order(), ['b', 'a', 'c']);

    await LxSourceManager.instance.move('c', 1); // 上移
    expect(order(), ['b', 'c', 'a']);

    await LxSourceManager.instance.move('a', 0); // 移到最前
    expect(order(), ['a', 'b', 'c']);
  });

  test('越界的位置夹到两头，不存在的 id 不动', () async {
    await reset(['a', 'b', 'c']);
    await LxSourceManager.instance.move('a', 99);
    expect(order(), ['b', 'c', 'a']);
    await LxSourceManager.instance.move('c', -5);
    expect(order(), ['c', 'b', 'a']);
    await LxSourceManager.instance.move('zzz', 0);
    expect(order(), ['c', 'b', 'a']);
  });

  test('顺序会存下来，重开 App 还是这个顺序', () async {
    await reset(['a', 'b', 'c']);
    await LxSourceManager.instance.move('c', 0);
    final prefs = await SharedPreferences.getInstance();
    final saved = (jsonDecode(prefs.getString('lx_sources_index')!) as List)
        .map((e) => (e as Map)['id'])
        .toList();
    expect(saved, ['c', 'a', 'b']);

    await LxSourceManager.instance.reloadFromStorage();
    expect(order(), ['c', 'a', 'b']);
  });
}
