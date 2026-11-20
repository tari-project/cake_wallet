/// Serialize native reads, throttle scan progress, and discard results of old sessions.
class MinotariBalanceUpdater<T> {
  MinotariBalanceUpdater(
      {required this.read,
      required this.publish,
      this.progressInterval = const Duration(seconds: 20),
      Duration Function()? elapsed})
      : _elapsed = elapsed;
  final Future<T?> Function() read;
  final void Function(T) publish;
  final Duration progressInterval;
  final Duration Function()? _elapsed;
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _tail = Future.value();
  Duration? _lastProgressAttempt;
  int _generation = 0;
  void beginScan() => _lastProgressAttempt = null;
  void invalidate() {
    _generation++;
    _lastProgressAttempt = null;
  }

  Future<void> get idle => _tail;
  Future<void> refresh({bool force = true}) {
    final generation = _generation;
    final result = _tail.then((_) async {
      if (generation != _generation) return;
      if (!force) {
        final now = _elapsed?.call() ?? _clock.elapsed;
        if (_lastProgressAttempt != null && now - _lastProgressAttempt! < progressInterval) return;
        _lastProgressAttempt = now;
      }
      final next = await read();
      if (generation == _generation && next != null) publish(next);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
