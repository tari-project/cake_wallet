import 'package:cw_core/amount/money.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_minotari/minotari_explorer.dart';

class MinotariTransactionInfo extends TransactionInfo {
  MinotariTransactionInfo({
    required String id,
    required Money amount,
    required DateTime date,
    required TransactionDirection direction,
    required bool isPending,
    Money? fee,
    int? height,
    int confirmations = 0,
    List<String>? payrefs,
  }) {
    final payrefsList = payrefs ?? [];
    this.id = id;
    // Keep row identity stable when a pending payment acquires its mined PayRef.
    this.txHash = id;
    additionalInfo['payrefs'] = List<String>.unmodifiable(payrefsList);
    additionalInfo['explorerUrl'] = minotariExplorerUrl(height: height, payrefs: payrefsList);
    this.amount = amount;
    this.date = date;
    this.direction = direction;
    this.isPending = isPending;
    this.fee = fee;
    this.height = height;
    this.confirmations = confirmations;
  }
}
