import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lxscript/lx_script_runtime.dart';

/// 洛雪的 lx.currentScriptInfo：从脚本头注释取元信息。「独家音源 v7」读
/// currentScriptInfo.version，以前 App 不给，脚本一加载就崩。
void main() {
  test('从头注释取 name / version / author，附上原文', () {
    const script =
        '/*!\n'
        ' * @name 独家音源\n'
        ' * @description 后续更新，请关注微信公众号\n'
        ' * @version 7\n'
        ' * @author w\n'
        ' */\n'
        'const a = 1';
    final info = LxScriptRuntime.scriptInfo(script);
    expect(info['name'], '独家音源');
    expect(info['version'], '7');
    expect(info['author'], 'w');
    expect(info['description'], '后续更新，请关注微信公众号');
    expect(info['homepage'], '');
    expect(info['rawScript'], script);
  });

  test('没有头注释也不崩，字段为空', () {
    final info = LxScriptRuntime.scriptInfo('const a = 1');
    expect(info['name'], '');
    expect(info['version'], '');
  });
}
