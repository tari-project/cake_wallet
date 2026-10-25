import "package:cw_minotari/src/rust/api/transactions.dart";

bool minotariIsPending(DisplayedTransactionStatus status) =>
    status == DisplayedTransactionStatus.pending ||
    status == DisplayedTransactionStatus.unconfirmed;

/// Special states must not be labelled Receiving/Sending in the history.
/// These match the existing XTM status names shown in transaction details.
String? minotariHistoryStatus(DisplayedTransactionStatus status) => switch (status) {
      DisplayedTransactionStatus.locked => "Locked",
      DisplayedTransactionStatus.cancelled => "Cancelled",
      DisplayedTransactionStatus.rejected => "Rejected",
      DisplayedTransactionStatus.reorganized => "Reorganized",
      _ => null,
    };
