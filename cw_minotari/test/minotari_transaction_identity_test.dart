import "package:cw_core/transaction_direction.dart";
import "package:cw_minotari/minotari_transaction_history.dart";
import "package:cw_minotari/minotari_transaction_info.dart";
import "package:flutter_test/flutter_test.dart";

// Synthetic references and wallet-local IDs; no live-wallet data.
final firstReference = List.filled(64, "a").join();
final replacementReference = List.filled(64, "b").join();

MinotariTransactionInfo transaction({
  required String id,
  TransactionDirection direction = TransactionDirection.outgoing,
  int height = 0,
  int confirmations = 0,
  List<String> payrefs = const [],
}) =>
    MinotariTransactionInfo(
      id: id,
      amount: 20000000,
      fee: direction == TransactionDirection.outgoing ? 700 : null,
      date: DateTime.utc(2026, 10, 12, 0, height == 0 ? 0 : 1),
      direction: direction,
      isPending: confirmations < 3,
      height: height,
      confirmations: confirmations,
      payrefs: payrefs,
    );

void main() {
  test("pending send keeps its row identity when mined and confirmed", () {
    final history = MinotariTransactionHistory();
    final other = transaction(id: "18446744073709551614");
    final pending = transaction(id: "18446744073709551615");
    history.addMany({pending.id: pending, other.id: other});
    final pendingIdentity = pending.txHash;

    expect(pendingIdentity, isNot(other.txHash));
    expect(pending.additionalInfo["explorerUrl"], isNull);

    for (final confirmations in [0, 1, 2, 3]) {
      final mined = transaction(
        id: pending.id,
        height: 42,
        confirmations: confirmations,
        payrefs: [firstReference],
      );
      history.addMany({mined.id: mined});

      // Stable identity lets Cake replace its cached pending row, even when
      // the payment reference and timestamp appear/change during mining.
      expect(mined.txHash, pendingIdentity);
      expect(history.transactions, hasLength(2));
      expect(history.transactions[mined.id], same(mined));
      expect(history.transactions[other.id], same(other));
      expect(mined.amount.amount, BigInt.from(20000000));
      expect(mined.fee!.amount, BigInt.from(700));
      expect(mined.confirmations, confirmations);
      expect(mined.isPending, confirmations < 3);
      expect(mined.additionalInfo["payrefs"], [firstReference]);
      expect(
        mined.additionalInfo["explorerUrl"],
        "https://explore.tari.com/blocks/42?payref=$firstReference",
      );
    }
  });

  test("a changed mined PayRef updates the link without changing row identity", () {
    final before = transaction(id: "101", height: 42, payrefs: [firstReference]);
    final after = transaction(id: before.id, height: 43, payrefs: [replacementReference]);

    expect(after.txHash, before.txHash);
    expect(after.additionalInfo["payrefs"], [replacementReference]);
    expect(
      after.additionalInfo["explorerUrl"],
      "https://explore.tari.com/blocks/43?payref=$replacementReference",
    );
  });

  test("incoming payments with distinct IDs stay distinct with or without PayRefs", () {
    final history = MinotariTransactionHistory();
    final first = transaction(id: "201", direction: TransactionDirection.incoming);
    final second = transaction(id: "202", direction: TransactionDirection.incoming);
    history.addMany({first.id: first, second.id: second});

    expect(first.txHash, isNot(second.txHash));
    final confirmed = transaction(
      id: first.id,
      direction: first.direction,
      height: 42,
      confirmations: 3,
      payrefs: [firstReference],
    );
    history.addOne(confirmed);
    expect(confirmed.txHash, first.txHash);
    expect(confirmed.isPending, isFalse);
    expect(history.transactions, hasLength(2));
    expect(history.transactions[first.id], same(confirmed));
    expect(history.transactions[second.id], same(second));
    expect(confirmed.additionalInfo["payrefs"], [firstReference]);
  });
}
