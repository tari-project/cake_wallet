import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/output_info.dart';

class PendingMinotariTransaction with PendingTransaction {
  @override
  final Money amount;
  @override
  final Money fee;
  final String recipientAddress;
  final Future<String> Function() sendTransaction;

  String? _txId;

  /// [amount] and [fee] are µT.
  PendingMinotariTransaction({
    required int amount,
    required int fee,
    required this.recipientAddress,
    required this.sendTransaction,
  })  : amount = Money.fromInt(amount, CryptoCurrency.xtm),
        fee = Money.fromInt(fee, CryptoCurrency.xtm);

  @override
  String get id => _txId ?? '';

  @override
  String get amountFormatted => amount.toString();

  @override
  String get hex => _txId ?? '';

  @override
  Future<void> commit() async {
    _txId = await sendTransaction();
  }

  @override
  Future<Map<String, String>> commitUR() async {
    // UR (Uniform Resources) not supported for Minotari
    throw UnimplementedError('UR not supported for Minotari');
  }
}

class MinotariTransactionCredentials {
  final List<OutputInfo> outputs;

  MinotariTransactionCredentials(this.outputs);
}
