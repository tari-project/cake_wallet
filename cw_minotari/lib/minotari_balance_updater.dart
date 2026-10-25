import "package:cw_minotari/minotari_balance.dart";

/// Serialize native balance reads and limit intermediate scan refreshes.
/// The native wallet remains the source of all amounts; this only schedules reads.
class MinotariBalanceUpdater {
  MinotariBalanceUpdater({
    required this.readBalance,
    required this.currentBalance,
    required this.publishBalance,
    this.progressInterval = const Duration(seconds: 20),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed;

  final Future<MinotariBalance?> Function() readBalance;
  final MinotariBalance? Function() currentBalance;
  final void Function(MinotariBalance) publishBalance;
  final Duration progressInterval;
  final Duration Function()? _elapsed;
  final _clock = Stopwatch()..start();
  Future<void> _tail = Future<void>.value();
  Duration? _lastProgressAttempt;
  int _generation = 0;

  /// Every pass may publish its first committed batch immediately.
  void beginScan() => _lastProgressAttempt = null;

  /// Discard queued/in-flight results when stopping or switching wallets/nodes.
  void invalidate() {
    _generation++;
    _lastProgressAttempt = null;
  }

  Future<void> get idle => _tail;

  /// Returns true when a current native balance was read successfully.
  /// Forced reads (opening, send, end of scan) bypass the progress limit.
  Future<bool> refresh({bool force = true, bool Function()? isCurrent}) {
    final generation = _generation;
    bool current() => generation == _generation && (isCurrent?.call() ?? true);

    final result = _tail.then((_) async {
      if (!current()) {
        return false;
      }
      if (!force) {
        final now = _elapsed?.call() ?? _clock.elapsed;
        final last = _lastProgressAttempt;
        if (last != null && now - last < progressInterval) {
          return false;
        }
        // Failed intermediate reads are also rate-limited; final reads still retry.
        _lastProgressAttempt = now;
      }
      final next = await readBalance();
      if (!current() || next == null) {
        return false;
      }
      final previous = currentBalance();
      if (previous == null ||
          previous.available != next.available ||
          previous.pendingIncoming != next.pendingIncoming ||
          previous.pendingOutgoing != next.pendingOutgoing) {
        publishBalance(next);
      }
      return true;
    });
    // A failed read must not prevent the next queued/final refresh from running.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
