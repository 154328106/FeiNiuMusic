/// 「这首取不到地址」的会话标记，带过期时间。
///
/// 以前是普通 Set：一首歌只要失败过一次（比如当时音源恰好挂了、脚本超时），
/// 这次启动里就一直被当成「取不到」，排队时直接筛掉、点了也跳。2026-11-05
/// 「保证能播」：标记 [ttl] 后自动失效，下次再点会重新去取。
class ExpiringSet<T> {
  ExpiringSet(this.ttl);

  final Duration ttl;
  final Map<T, DateTime> _until = {};

  bool add(T value) {
    final had = contains(value);
    _until[value] = DateTime.now().add(ttl);
    return !had;
  }

  bool contains(T value) {
    final t = _until[value];
    if (t == null) return false;
    if (DateTime.now().isBefore(t)) return true;
    _until.remove(value);
    return false;
  }

  bool remove(T value) => _until.remove(value) != null;

  void clear() => _until.clear();
}
