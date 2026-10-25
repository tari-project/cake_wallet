import "package:cw_core/transaction_direction.dart";
import "package:cw_minotari/minotari_explorer.dart";
import "package:cw_minotari/minotari_transaction_info.dart";
import "package:flutter_test/flutter_test.dart";

const reference = "9cb2bb582664d051387c2d40ed638be2d7d98226b64ced71f90827a8e73f5a1a";

void main() {
  test("incoming metadata keeps wallet ID separate from the payment link", () {
    final refs = [reference];
    final tx = MinotariTransactionInfo(
      id: "15594178869593306621",
      amount: 100000000,
      date: DateTime.utc(2026),
      direction: TransactionDirection.incoming,
      isPending: true,
      height: 363574,
      payrefs: refs,
    );
    refs.clear();
    expect(tx.id, "15594178869593306621");
    expect(tx.additionalInfo["payrefs"], [reference]);
    expect(
      tx.additionalInfo["explorerUrl"],
      "https://explore.tari.com/blocks/363574?payref=$reference",
    );
  });

  test("testnet uses the Esmeralda explorer and normalizes a valid reference", () {
    expect(
      minotariExplorerUrl(height: 42, payrefs: [reference.toUpperCase()], isTestnet: true),
      "https://explore-esmeralda.tari.com/blocks/42?payref=$reference",
    );
  });

  test("unmined or unknown-height transactions do not have a block link", () {
    for (final height in <int?>[null, 0, -1]) {
      expect(minotariExplorerUrl(height: height, payrefs: [reference]), isNull);
    }
  });

  test("missing reference falls back to the known block without inventing an ID", () {
    expect(minotariExplorerUrl(height: 42, payrefs: []), "https://explore.tari.com/blocks/42");
    expect(
      minotariExplorerUrl(height: 42, payrefs: ["null", "6003262648683201031"]),
      "https://explore.tari.com/blocks/42",
    );
    expect(
      minotariExplorerUrl(height: 42, payrefs: ["bad", reference]),
      "https://explore.tari.com/blocks/42?payref=$reference",
    );
  });
}
