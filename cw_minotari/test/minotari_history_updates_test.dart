import "dart:async";

import "package:cw_core/transaction_direction.dart";
import "package:cw_minotari/minotari_transaction_history.dart";
import "package:cw_minotari/minotari_transaction_info.dart";
import "package:flutter_test/flutter_test.dart";

class RecordingHistory extends MinotariTransactionHistory {
  int saves = 0;

  @override
  Future<void> save() async {
    saves++;
  }
}

MinotariTransactionInfo transaction(String id, {int confirmations = 0}) {
  final tx = MinotariTransactionInfo(
    id: id,
    amount: 20000000,
    fee: 700,
    date: DateTime.utc(2026, 1, 1),
    direction: TransactionDirection.outgoing,
    isPending: confirmations < 3,
    height: confirmations == 0 ? 0 : 42,
    confirmations: confirmations,
    payrefs: confirmations == 0 ? [] : [List.filled(64, "a").join()],
  );
  tx.additionalInfo["status"] = confirmations < 3 ? "unconfirmed" : "confirmed";
  return tx;
}

void main() {
  test("empty and identical updates do not replace records or save history", () async {
    final history = RecordingHistory();
    final old = transaction("1");
    history.addOne(old);
    await history.applyChanges<int>([], (_) => throw StateError("must not map an empty update"));
    await history.applyChanges([transaction("1")], (tx) => tx);
    expect(history.transactions["1"], same(old));
    expect(history.saves, 0);
  });

  test("changed rows update in place and preserve unrelated old history", () async {
    final history = RecordingHistory();
    final unrelated = transaction("2", confirmations: 3);
    history.addMany({"1": transaction("1"), "2": unrelated});
    for (final confirmations in [1, 2, 3]) {
      await history.applyChanges([transaction("1", confirmations: confirmations)], (tx) => tx);
      expect(history.transactions, hasLength(2));
      expect(history.transactions["2"], same(unrelated));
      final updated = history.transactions["1"]!;
      expect(updated.confirmations, confirmations);
      expect(updated.isPending, confirmations < 3);
      expect(updated.amount.amount, BigInt.from(20000000));
      expect(updated.fee!.amount, BigInt.from(700));
      expect(updated.additionalInfo["explorerUrl"], contains("/blocks/42?payref="));
    }
    expect(history.saves, 3);
    await history.applyChanges([transaction("3", confirmations: 3)], (tx) => tx);
    expect(history.transactions, hasLength(3));
  });

  test("large mapping yields to the event loop", () async {
    var yielded = false;
    Timer.run(() => yielded = true);
    final mapped = await mapMinotariTransactions(
      List.generate(1000, (index) => index.toString()),
      transaction,
    );
    expect(yielded, isTrue);
    expect(mapped, hasLength(1000));
  });

  test("closing a wallet during mapping discards the whole stale update", () async {
    final history = RecordingHistory();
    final existing = transaction("old");
    history.addOne(existing);
    var current = true;
    Timer.run(() => current = false);
    await history.applyChanges(
      List.generate(1000, (index) => index.toString()),
      transaction,
      isCurrent: () => current,
    );
    expect(history.transactions, hasLength(1));
    expect(history.transactions["old"], same(existing));
    expect(history.saves, 0);
  });

  test("snapshot and delta tasks cannot overlap and an error does not stop retries", () async {
    final queue = MinotariHistoryUpdateQueue();
    final released = Completer<void>();
    final events = <String>[];
    final snapshot = queue.run(() async {
      events.add("snapshot started");
      await released.future;
      events.add("snapshot completed");
    });
    final delta = queue.run(() async => events.add("delta"));
    await Future<void>.delayed(Duration.zero);
    expect(events, ["snapshot started"]);
    released.complete();
    await Future.wait([snapshot, delta]);
    expect(events, ["snapshot started", "snapshot completed", "delta"]);

    final error = StateError("synthetic transport error");
    await expectLater(queue.run(() async => throw error), throwsA(same(error)));
    await queue.run(() async => events.add("retry"));
    expect(events.last, "retry");
  });
}
