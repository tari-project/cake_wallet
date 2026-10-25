import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/format_amount.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_minotari/minotari_explorer.dart';

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
    bool isTestnet = false,
  }) {
    final payrefsList = payrefs ?? [];
    this.id = id;
    // Cake matches history rows by txHash. The wallet-local ID stays stable
    // from pending to mined; PayRefs belong only to the payment/explorer data.
    txHash = id;
    this.amount = Money.fromInt(amount, CryptoCurrency.xtm);
    this.date = date;
    this.direction = direction;
    this.isPending = isPending;
    this.fee = fee == null ? null : Money.fromInt(fee, CryptoCurrency.xtm);
    this.height = height;
    this.confirmations = confirmations;
    additionalInfo['payrefs'] = List<String>.unmodifiable(payrefsList);
    additionalInfo['explorerUrl'] = minotariExplorerUrl(
      height: height,
      payrefs: payrefsList,
      isTestnet: isTestnet,
    );
  }
  String? _fiatAmount;

  String amountFormatted() => amount.toStringWithSymbol();

  @override
  String fiatAmount() => _fiatAmount ?? '';

  @override
  void changeFiatAmount(String amount) => _fiatAmount = formatAmount(amount);

  String? feeFormatted() {
    return fee?.toStringWithSymbol();
  }
}
