import 'package:cw_core/amount/money.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';

class TariOotleTransactionInfo extends TransactionInfo {
  TariOotleTransactionInfo({
    required String id,
    required Money amount,
    required Money fee,
    required TransactionDirection direction,
    required bool isPending,
    required DateTime date,
    String? counterparty,
  }) {
    this.id = id;
    this.amount = amount;
    this.fee = fee;
    this.direction = direction;
    this.isPending = isPending;
    this.date = date;
    if (direction == TransactionDirection.incoming) {
      from = counterparty;
    } else {
      to = counterparty;
    }
  }
}
