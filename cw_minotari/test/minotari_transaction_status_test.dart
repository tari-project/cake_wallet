import "package:cw_minotari/minotari_transaction_status.dart";
import "package:cw_minotari/src/rust/api/transactions.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("only Pending and Unconfirmed are waiting for receipt/send", () {
    for (final status in DisplayedTransactionStatus.values) {
      expect(
        minotariIsPending(status),
        status == DisplayedTransactionStatus.pending ||
            status == DisplayedTransactionStatus.unconfirmed,
        reason: status.name,
      );
    }
  });

  test("special states keep their own history labels", () {
    expect(minotariHistoryStatus(DisplayedTransactionStatus.locked), "Locked");
    expect(minotariHistoryStatus(DisplayedTransactionStatus.cancelled), "Cancelled");
    expect(minotariHistoryStatus(DisplayedTransactionStatus.rejected), "Rejected");
    expect(minotariHistoryStatus(DisplayedTransactionStatus.reorganized), "Reorganized");
    for (final status in [
      DisplayedTransactionStatus.pending,
      DisplayedTransactionStatus.unconfirmed,
      DisplayedTransactionStatus.confirmed,
    ]) {
      expect(minotariHistoryStatus(status), isNull);
    }
  });
}
