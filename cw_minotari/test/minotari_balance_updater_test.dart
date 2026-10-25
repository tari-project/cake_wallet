import "dart:async";

import "package:cw_minotari/minotari_balance.dart";
import "package:cw_minotari/minotari_balance_updater.dart";
import "package:cw_minotari/minotari_sync_loop.dart";
import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";

MinotariBalance amounts(int available, {int incoming = 0, int locked = 0}) => MinotariBalance(
      available: available,
      pendingIncoming: incoming,
      pendingOutgoing: locked,
    );

void main() {
  test("a long scan publishes committed balances before completion and always reads at the end",
      () {
    fakeAsync((clock) {
      final source = StreamController<MinotariBalance>();
      var native = amounts(10);
      MinotariBalance? visible;
      var reads = 0;
      var synced = false;
      final updater = MinotariBalanceUpdater(
        elapsed: () => clock.elapsed,
        readBalance: () async {
          reads++;
          return native;
        },
        currentBalance: () => visible,
        publishBalance: (value) => visible = value,
      );
      final loop = MinotariSyncLoop<MinotariBalance>(
        scan: (_) async {
          updater.beginScan();
          return source.stream;
        },
        onEvent: (committed, current) async {
          native = committed;
          await updater.refresh(force: false, isCurrent: current);
        },
        refresh: (current) async {
          await updater.refresh(isCurrent: current);
        },
        onSynced: () => synced = true,
        onError: (error, _) => fail("$error"),
      );
      unawaited(loop.start());
      clock.flushMicrotasks();
      source.add(amounts(20, incoming: 5));
      clock.flushMicrotasks();
      expect(visible!.available.amount, BigInt.from(20));
      expect(visible!.pendingIncoming.amount, BigInt.from(5));
      expect(synced, isFalse, reason: "balance must update while the stream is still open");

      for (var i = 0; i < 100; i++) {
        source.add(amounts(30 + i, incoming: 5));
      }
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 19));
      expect(reads, 1, reason: "a burst of batches must not cause a burst of DB reads");
      clock.elapse(const Duration(seconds: 1));
      source.add(amounts(140, locked: 2));
      clock.flushMicrotasks();
      expect(reads, 2);
      expect(visible!.available.amount, BigInt.from(140));
      expect(visible!.pendingOutgoing.amount, BigInt.from(2));

      source.add(amounts(150)); // within the limit, but the final refresh must read it
      unawaited(source.close());
      clock.flushMicrotasks();
      expect(reads, 3);
      expect(visible!.available.amount, BigInt.from(150));
      expect(visible!.pendingOutgoing.amount, BigInt.zero);
      expect(synced, isTrue);
      unawaited(loop.stop());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test("opening and sending bypass the intermediate limit", () async {
    var now = Duration.zero;
    var reads = 0;
    MinotariBalance? visible;
    final updater = MinotariBalanceUpdater(
      elapsed: () => now,
      readBalance: () async => amounts(++reads),
      currentBalance: () => visible,
      publishBalance: (value) => visible = value,
    );
    await updater.refresh(force: false);
    now = const Duration(seconds: 1);
    expect(await updater.refresh(force: false), isFalse);
    await updater.refresh();
    await updater.refresh();
    expect(reads, 3);
    expect(visible!.available.amount, BigInt.from(3));
  });

  test("a new scan reads its first batch even inside the previous limit", () async {
    var reads = 0;
    final updater = MinotariBalanceUpdater(
      elapsed: () => Duration.zero,
      readBalance: () async {
        reads++;
        return amounts(10);
      },
      currentBalance: () => null,
      publishBalance: (_) {},
    );
    await updater.refresh(force: false);
    expect(await updater.refresh(force: false), isFalse);
    updater.beginScan();
    expect(await updater.refresh(force: false), isTrue);
    expect(reads, 2);
  });

  test("unchanged amounts preserve the published instance; each native amount matters", () async {
    var native = amounts(10, incoming: 2, locked: 3);
    MinotariBalance? visible;
    var publications = 0;
    final updater = MinotariBalanceUpdater(
      readBalance: () async => native,
      currentBalance: () => visible,
      publishBalance: (value) {
        publications++;
        visible = value;
      },
    );
    await updater.refresh();
    final original = visible;
    native = amounts(10, incoming: 2, locked: 3);
    await updater.refresh();
    expect(visible, same(original));
    expect(publications, 1);
    // Same aggregate unavailable balance, but different incoming/locked portions.
    native = amounts(10, incoming: 3, locked: 2);
    await updater.refresh();
    expect(publications, 2);
    native = amounts(11, incoming: 3, locked: 2);
    await updater.refresh();
    expect(publications, 3);
    native = amounts(11, incoming: 4, locked: 2);
    await updater.refresh();
    expect(publications, 4);
    native = amounts(11, incoming: 4, locked: 3);
    await updater.refresh();
    expect(publications, 5);
  });

  test("progress and forced reads are serialized and cannot overwrite newer balances", () async {
    final responses = <Completer<MinotariBalance>>[];
    MinotariBalance? visible;
    final updater = MinotariBalanceUpdater(
      readBalance: () {
        final response = Completer<MinotariBalance>();
        responses.add(response);
        return response.future;
      },
      currentBalance: () => visible,
      publishBalance: (value) => visible = value,
    );
    final progress = updater.refresh(force: false);
    final send = updater.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(responses, hasLength(1));
    responses[0].complete(amounts(10));
    await progress;
    await Future<void>.delayed(Duration.zero);
    expect(responses, hasLength(2));
    responses[1].complete(amounts(20));
    await send;
    expect(visible!.available.amount, BigInt.from(20));
  });

  test("stopping discards in-flight and queued reads before the native DB closes", () async {
    final response = Completer<MinotariBalance>();
    var reads = 0;
    var publications = 0;
    final updater = MinotariBalanceUpdater(
      readBalance: () {
        reads++;
        return response.future;
      },
      currentBalance: () => null,
      publishBalance: (_) => publications++,
    );
    final running = updater.refresh();
    final queued = updater.refresh();
    await Future<void>.delayed(Duration.zero);
    updater.invalidate();
    var idle = false;
    unawaited(updater.idle.then((_) => idle = true));
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    response.complete(amounts(10));
    expect(await running, isFalse);
    expect(await queued, isFalse);
    await updater.idle;
    expect(reads, 1);
    expect(publications, 0);
    expect(idle, isTrue);
    expect(await updater.refresh(), isTrue, reason: "reconnecting can read again");
  });

  test("a superseded sync result is not published even without cancelling the native read",
      () async {
    final response = Completer<MinotariBalance>();
    var current = true;
    var publications = 0;
    final updater = MinotariBalanceUpdater(
      readBalance: () => response.future,
      currentBalance: () => null,
      publishBalance: (_) => publications++,
    );
    final pending = updater.refresh(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    response.complete(amounts(10));
    expect(await pending, isFalse);
    expect(publications, 0);
  });

  test("a failed progress read retains the last balance and final refresh retries immediately",
      () async {
    final previous = amounts(10);
    var visible = previous;
    var reads = 0;
    final error = StateError("synthetic SQLite failure");
    final updater = MinotariBalanceUpdater(
      elapsed: () => Duration.zero,
      readBalance: () async {
        if (++reads == 1) {
          throw error;
        }
        return amounts(20);
      },
      currentBalance: () => visible,
      publishBalance: (value) => visible = value,
    );
    await expectLater(updater.refresh(force: false), throwsA(same(error)));
    expect(visible, same(previous));
    expect(await updater.refresh(force: false), isFalse);
    expect(await updater.refresh(), isTrue);
    expect(reads, 2);
    expect(visible.available.amount, BigInt.from(20));
  });
}
