import 'package:cw_core/amount/money.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_priority.dart';

class PendingMinotariTransaction with PendingTransaction {
  PendingMinotariTransaction({
    required this.amount,
    required this.fee,
    required this.send,
    required this.isFeeEstimate,
  });

  @override
  final Money amount;

  @override
  final Money fee;

  /// Broadcasts the send and returns cw's id of the recorded transaction, if cw reported one.
  final Future<String?> Function() send;

  /// The quote is an upper bound on the signed kernel fee. Native code refuses
  /// any increase before broadcast, so a changed input selection needs a new quote.
  @override
  final bool isFeeEstimate;

  String _id = '';

  /// cw's id of the recorded transaction (its key in the history), once committed.
  @override
  String get id => _id;

  @override
  String get amountFormatted => amount.toStringWithSymbol();

  @override
  String get hex => '';

  @override
  Future<void> commit() async => _id = await send() ?? '';

  @override
  Future<Map<String, String>> commitUR() =>
      throw UnsupportedError('UR is not supported for Minotari');
}

class MinotariTransactionCredentials {
  final List<OutputInfo> outputs;
  final TransactionPriority? priority;

  /// The abandoned send this one pays again, so that only one of them can be mined.
  final String? conflictsWithTransactionId;

  MinotariTransactionCredentials(this.outputs, {this.priority, this.conflictsWithTransactionId});
}
