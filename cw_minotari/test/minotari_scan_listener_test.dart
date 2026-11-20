import 'dart:async';

import 'package:cw_minotari/minotari_scan_listener.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

void main() {
  test('a refused background scan owns its terminal event and detached FRB error', () async {
    final events = <String>[];
    final errors = <Object>[];
    final error = AnyhowException('A foreground scan of this wallet is already running');
    listenMinotariScan<String>(
      stream: () {
        // This matches generated FRB stream calls: the Result future is not
        // returned to the caller, and its error is separate from stream events.
        unawaited(Future<void>.delayed(Duration.zero, () => throw error));
        return Stream.value('Handled by foreground');
      },
      onData: events.add,
      onError: (error, stack) => errors.add(error),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, ['Handled by foreground']);
    expect(errors, [same(error)]);
  });

  test('successful scan events reach the listener in order', () async {
    final events = <String>[];
    listenMinotariScan<String>(
      stream: () => Stream.fromIterable(['Started', 'Progress', 'Completed']),
      onData: events.add,
      onError: (error, stack) => fail('Unexpected scan error: $error'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, ['Started', 'Progress', 'Completed']);
  });

  test('a stream error is delivered to the same scan error handler', () async {
    final error = StateError('offline');
    final received = Completer<Object>();
    listenMinotariScan<String>(
      stream: () => Stream.error(error),
      onData: (_) => fail('No data'),
      onError: (error, stack) => received.complete(error),
    );
    expect(await received.future, same(error));
  });

  test('an unexpected detached bridge error is reported rather than discarded', () async {
    final error = StateError('decoder failure');
    final received = Completer<Object>();
    listenMinotariScan<String>(
      stream: () {
        unawaited(Future<void>.error(error));
        return const Stream.empty();
      },
      onData: (_) => fail('No data'),
      onError: (error, stack) => received.complete(error),
    );
    expect(await received.future, same(error));
  });

  test('synchronous startup failure uses the scan error handler', () {
    final error = StateError('invalid configuration');
    final errors = <Object>[];
    listenMinotariScan<String>(
      stream: () => throw error,
      onData: (_) => fail('No data'),
      onError: (error, stack) => errors.add(error),
    );
    expect(errors, [same(error)]);
  });
}
