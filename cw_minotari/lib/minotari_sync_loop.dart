import "dart:async";

/// Serialized scan/refresh cycles. Closing or restarting invalidates old results.
class MinotariSyncLoop<T> {
  MinotariSyncLoop({
    required this.scan,
    required this.onEvent,
    required this.refresh,
    required this.onSynced,
    required this.onError,
    this.interval = const Duration(seconds: 20),
  });

  final Future<Stream<T>> Function(bool Function() isCurrent) scan;
  final Future<void> Function(T event, bool Function() isCurrent) onEvent;
  final Future<void> Function(bool Function() isCurrent) refresh;
  final void Function() onSynced;
  final void Function(Object error, StackTrace stack) onError;
  final Duration interval;

  int _generation = 0;
  Timer? _timer;
  StreamSubscription<T>? _subscription;
  Completer<bool>? _done;
  Future<void> _cycle = Future<void>.value();

  Future<void> start({bool repeat = true}) async {
    final generation = ++_generation;
    await _cancelCycle();
    if (generation != _generation) {
      return;
    }
    _cycle = _runCycle(generation, repeat: repeat);
  }

  Future<void> stop() async {
    ++_generation;
    await _cancelCycle();
  }

  /// A background job waits for the final event and refresh, with no retry timer.
  Future<void> runOnce() async {
    await start(repeat: false);
    await _cycle;
  }

  Future<void> _cancelCycle() async {
    _timer?.cancel();
    _timer = null;
    final running = _cycle;
    final subscription = _subscription;
    _subscription = null;
    final done = _done;
    if (done != null && !done.isCompleted) {
      done.complete(false);
    }
    await subscription?.cancel();
    await running;
  }

  Future<void> _runCycle(int generation, {required bool repeat}) async {
    bool isCurrent() => generation == _generation;
    StreamSubscription<T>? subscription;
    final done = Completer<bool>();
    Future<void> events = Future<void>.value();
    Object? eventError;
    StackTrace? eventStack;
    void recordError(Object error, StackTrace stack) {
      eventError ??= error;
      eventStack ??= stack;
      if (!done.isCompleted) {
        done.complete(true);
      }
    }

    try {
      final stream = await scan(isCurrent);
      if (!isCurrent()) {
        return;
      }
      _done = done;
      subscription = stream.listen(
        (event) {
          events = events.then<void>((_) async {
            if (isCurrent() && eventError == null) {
              await onEvent(event, isCurrent);
            }
          }).catchError(recordError);
        },
        onError: recordError,
        onDone: () {
          if (!done.isCompleted) {
            done.complete(true);
          }
        },
        cancelOnError: true,
      );
      _subscription = subscription;
      final completed = await done.future;
      await events;
      if (!completed || !isCurrent()) {
        return;
      }
      if (eventError != null) {
        Error.throwWithStackTrace(eventError!, eventStack!);
      }
      await refresh(isCurrent);
      if (isCurrent()) {
        onSynced();
      }
    } catch (error, stack) {
      if (isCurrent()) {
        onError(error, stack);
      }
    } finally {
      await subscription?.cancel();
      await events;
      if (identical(_subscription, subscription)) {
        _subscription = null;
      }
      if (identical(_done, done)) {
        _done = null;
      }
      if (repeat && isCurrent()) {
        _timer = Timer(interval, () {
          _timer = null;
          _cycle = _runCycle(generation, repeat: repeat);
        });
      }
    }
  }
}
