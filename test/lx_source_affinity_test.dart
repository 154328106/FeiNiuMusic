import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/lxscript/lx_source_manager.dart';

/// 2026-11-12：脚本是串行逐个问的，而备用脚本 inited 时同样声明支持全部平台
/// （声明 ≠ 真有货），所以排前面那个没货也得等它跑完（实测 2.4~6.5 秒）才轮到
/// 下一个 —— 表现成「切到网易要卡一下才出声」。改成记住上次命中的脚本，同平台
/// 下次先问它。这里验排序逻辑，脚本都设未启用，载入时不会起 JS 引擎。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mgr = LxSourceManager.instance;

  Map<String, Object> index(List<String> ids) => {
    'lx_sources_index': jsonEncode([
      for (final id in ids)
        {
          'id': id,
          'name': '脚本$id',
          'enabled': false,
          'sources': ['kg', 'wy'],
        },
    ]),
  };

  Future<void> reset(List<String> ids) async {
    SharedPreferences.setMockInitialValues(index(ids));
    await mgr.reloadFromStorage();
    mgr.lastHit.clear();
  }

  /// 这一轮实际会按什么顺序问脚本。
  List<String> asked(String platform) =>
      mgr.orderFor(platform).map((m) => m.id).toList();

  test('没有亲和记忆时，就按用户排的顺序问', () async {
    await reset(['a', 'b', 'c']);
    expect(asked('kg'), ['a', 'b', 'c']);
  });

  test('命中过的脚本下次提到最前，其余保持用户排的相对顺序', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'c';
    expect(asked('kg'), ['c', 'a', 'b']);
  });

  test('按平台各记各的，互不干扰', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'c';
    mgr.lastHit['wy'] = 'b';
    expect(asked('kg'), ['c', 'a', 'b']);
    expect(asked('wy'), ['b', 'a', 'c']);
    expect(asked('tx'), ['a', 'b', 'c'], reason: '没记忆的平台照用户顺序');
  });

  test('命中的本来就排第一，顺序不变', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'a';
    expect(asked('kg'), ['a', 'b', 'c']);
  });

  test('记着的脚本已经被删掉：回落到原顺序，不崩', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'zzz';
    expect(asked('kg'), ['a', 'b', 'c']);
  });

  test('亲和性不动 list()：用户在设置页排的顺序照样保存和显示', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'c';
    expect(
      mgr.list().map((m) => m.id).toList(),
      ['a', 'b', 'c'],
      reason: '它只影响运行时问询顺序，不该改用户看到的列表',
    );
  });

  test('主力源让出亲和位后，下一轮回到用户排的顺序', () async {
    await reset(['a', 'b', 'c']);
    mgr.lastHit['kg'] = 'c';
    expect(asked('kg'), ['c', 'a', 'b']);
    // 这轮它没给出可用链接 → resolve 里 _forgetHit 会把记忆清掉
    mgr.lastHit.remove('kg');
    expect(asked('kg'), ['a', 'b', 'c']);
  });
}
