import 'package:cw_core/transaction_history.dart';
import 'package:cw_tari_ootle/tari_ootle_transaction_info.dart';

class TariOotleTransactionHistory extends TransactionHistoryBase<TariOotleTransactionInfo> {
  @override
  void addOne(TariOotleTransactionInfo transaction) => transactions[transaction.id] = transaction;

  @override
  void addMany(Map<String, TariOotleTransactionInfo> transactions) =>
      this.transactions.addAll(transactions);

  /// History lives in the bridge's wallet store; nothing to persist here.
  @override
  Future<void> save() async {}
}
