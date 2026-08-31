/// Subsonic 响应的形状归一化。
///
/// 同一套 Subsonic API，不同服务端吐出来的 JSON 形状并不一样：
///
/// - **Navidrome 等标准实现**：属性平铺，`{"song": [{"id": "1", "title": "x"}]}`
/// - **由 XML 转出来的实现**（如 NAS 上 4000 端口那个）：属性裹在 `_attributes`
///   里，`{"song": [{"_attributes": {"id": "1", "title": "x"}}]}`
///
/// 另外 XML 转 JSON 还会带来两个副作用：单元素时给对象、多元素时才给数组；
/// 所有数字都变成字符串。三件事都在这里一次抹平，上层解析只面对一种形状。
library;

/// 递归把 `_attributes` / `_text` 包装拍平；标准形状原样返回。
Object? normalizeSubsonic(Object? value) {
  if (value is Map) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = '${entry.key}';
      if (key == '_attributes' || key == '_text') continue;
      out[key] = normalizeSubsonic(entry.value);
    }
    final attrs = value['_attributes'];
    if (attrs is Map) {
      for (final entry in attrs.entries) {
        out['${entry.key}'] = normalizeSubsonic(entry.value);
      }
    }
    // 纯文本节点（`{"_text": "..."}`）拍成裸值。
    final text = value['_text'];
    if (text != null && out.isEmpty) return text;
    return out;
  }
  if (value is List) return value.map(normalizeSubsonic).toList();
  return value;
}

/// 单元素给对象、多元素给数组 —— 统一成数组。
List<Map<String, Object?>> subsonicList(Object? value) {
  if (value is List) {
    return value.whereType<Map>().map(_asStringKeyed).toList();
  }
  if (value is Map) return [_asStringKeyed(value)];
  return const [];
}

Map<String, Object?> _asStringKeyed(Map<Object?, Object?> map) =>
    map.map((k, v) => MapEntry('$k', v));

/// XML 转出来的 JSON 里数字都是字符串，取值一律走这两个helper。
int subsonicInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String subsonicStr(Object? value, {String fallback = ''}) {
  if (value is String) return value;
  if (value is int || value is double) return '$value';
  return fallback;
}

bool subsonicBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}
