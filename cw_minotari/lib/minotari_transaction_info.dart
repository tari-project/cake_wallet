import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';

class MinotariTransactionInfo extends TransactionInfo {
  MinotariTransactionInfo({
    required String id,
    required int amount,
    required DateTime date,
    required TransactionDirection direction,
    required bool isPending,
    int? fee,
    int? height,
    int confirmations = 0,
    List<String>? payrefs,
  }) {
    final payrefsList = payrefs ?? [];
    this.id = id;
    // Use first payref as txHash for block explorer link generation
    this.txHash = payrefsList.isNotEmpty ? payrefsList.first : 'null';
    this.amount = Money.fromInt(amount, CryptoCurrency.xtm);
    this.date = date;
    this.direction = direction;
    this.isPending = isPending;
    this.fee = fee == null ? null : Money.fromInt(fee, CryptoCurrency.xtm);
    this.height = height;
    this.confirmations = confirmations;
  }
}
