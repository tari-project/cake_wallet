import 'package:cw_core/amount/money.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/transaction_priority.dart';

class PendingMinotariTransaction with PendingTransaction {
  final Money amount;
  final Money fee;
  final String recipientAddress;
  final Future<String> Function() sendTransaction;

  String? _txId;

  PendingMinotariTransaction({
    required this.amount,
    required this.fee,
    required this.recipientAddress,
    required this.sendTransaction,
  });

  @override
  String get id => _txId ?? '';

  @override
  String get amountFormatted => amount.toStringWithSymbol();

  @override
  String get feeFormatted => fee.toStringWithSymbol();

  @override
  String get feeFormattedValue => fee.toString();

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

  final TransactionPriority? priority;

  MinotariTransactionCredentials(this.outputs, {this.priority});
}
