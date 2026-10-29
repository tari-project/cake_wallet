import 'package:cw_core/amount/money.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';

class PendingTariOotleTransaction with PendingTransaction {
  PendingTariOotleTransaction({
    required this.amount,
    required this.fee,
    required this.recipientAddress,
    required Future<String> Function() send,
  }) : _send = send;

  @override
  final Money amount;

  /// The settled fee from the bridge's dry run; [commit] sends at exactly this fee.
  @override
  final Money fee;

  final String recipientAddress;
  final Future<String> Function() _send;
  String? _txId;

  @override
  String get id => _txId ?? '';

  @override
  String get amountFormatted => amount.toString();

  @override
  String get hex => '';

  @override
  Future<void> commit() async => _txId = await _send();

  @override
  Future<Map<String, String>> commitUR() => throw UnimplementedError();
}

class TariOotleTransactionCredentials {
  TariOotleTransactionCredentials(this.outputs);

  final List<OutputInfo> outputs;
}
