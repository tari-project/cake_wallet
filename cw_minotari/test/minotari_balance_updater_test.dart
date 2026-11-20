import 'dart:async';
import 'package:cw_minotari/minotari_balance_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('progress is throttled; final reads bypass the interval', () async {
    var now = Duration.zero;
    var reads = 0;
    final published = <int>[];
    final u = MinotariBalanceUpdater<int>(
        read: () async => ++reads, publish: published.add, elapsed: () => now);
    await u.refresh(force: false);
    await u.refresh(force: false);
    expect(reads, 1);
    now = const Duration(seconds: 20);
    await u.refresh(force: false);
    await u.refresh();
    expect(published, [1, 2, 3]);
  });
  test('a stopped session cannot publish a late result or perform queued reads', () async {
    final read = Completer<int?>();
    var reads = 0;
    final published = <int>[];
    final u = MinotariBalanceUpdater<int>(
        read: () {
          reads++;
          return read.future;
        },
        publish: published.add);
    final first = u.refresh();
    await Future<void>.delayed(Duration.zero);
    final queued = u.refresh();
    u.invalidate();
    read.complete(7);
    await Future.wait([first, queued]);
    expect(reads, 1);
    expect(published, isEmpty);
  });
  test('failed intermediate reads do not block the mandatory final read', () async {
    var reads = 0;
    final published = <int>[];
    final u = MinotariBalanceUpdater<int>(
        read: () async {
          if (++reads == 1) throw StateError('test');
          return 9;
        },
        publish: published.add);
    await expectLater(u.refresh(force: false), throwsStateError);
    await u.refresh(force: false);
    expect(reads, 1);
    await u.refresh();
    expect(published, [9]);
  });
  test('native reads are serialized and a new scan can refresh immediately', () async {
    var active = 0;
    var peak = 0;
    var reads = 0;
    final u = MinotariBalanceUpdater<int>(
        read: () async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          return ++reads;
        },
        publish: (_) {});
    await Future.wait([u.refresh(), u.refresh()]);
    expect(peak, 1);
    await u.refresh(force: false);
    u.beginScan();
    await u.refresh(force: false);
    expect(reads, 4);
  });
}
