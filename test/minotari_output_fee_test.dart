// XTM-only coverage of the common Output -> Minotari adapter path.
import 'dart:async';
import 'package:cake_wallet/minotari/minotari.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/dashboard/fiat_conversion_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/view_model/send/output.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_transaction_priority.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/pending_minotari_transaction.dart';
import 'package:cw_minotari/src/rust/api/fee.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';

class _Settings extends Fake implements SettingsStore {
  final selectedPriority = Observable<TransactionPriority>(MinotariTransactionPriority.medium);
  @override
  TransactionPriority? getPriority(WalletType type, {int? chainId}) => selectedPriority.value;
}

class _AppStore extends Fake implements AppStore {
  _AppStore(this.settingsStore);
  @override
  final SettingsStore settingsStore;
}

class _Wallet extends Fake implements MinotariWallet {
  final calls = <({BigInt amount, TransactionPriority? priority, String? note})>[];
  Future<FeeEstimate> Function(BigInt)? estimate;
  @override
  WalletType get type => WalletType.minotari;
  @override
  int? get chainId => null;
  @override
  SyncStatus get syncStatus => SyncedSyncStatus();
  @override
  Future<FeeEstimate> estimatePaymentFee(
      {required BigInt amount, TransactionPriority? priority, String? paymentId}) {
    calls.add((amount: amount, priority: priority, note: paymentId));
    return estimate?.call(amount) ?? Future.value(quote(amount));
  }
}

FeeEstimate quote(BigInt amount, {int fee = 500}) => FeeEstimate(
    estimatedFee: BigInt.from(fee),
    totalAmountRequired: amount + BigInt.from(fee),
    feePerGram: BigInt.from(5),
    inputCount: BigInt.one);
void main() {
  late _Wallet wallet;
  late _Settings settings;
  late Output output;
  setUp(() {
    wallet = _Wallet();
    settings = _Settings();
  });
  testWidgets('editing amount and note requests a debounced exact XTM amount', (tester) async {
    output = Output(wallet, _AppStore(settings), FiatConversionStore(),
        ([CryptoCurrency? _]) => CryptoCurrency.xtm);
    output.cryptoAmount = '9223372036854.775808';
    output.note = 'invoice-я';
    expect(wallet.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 301));
    expect(wallet.calls.single.amount, BigInt.parse('9223372036854775808'));
    expect(wallet.calls.single.note, 'invoice-я');
    expect(output.estimatedFee.amount, BigInt.from(500));
    runInAction(() => settings.selectedPriority.value = MinotariTransactionPriority.fast);
    expect(output.estimatedFee.amount, BigInt.zero);
    await tester.pump(const Duration(milliseconds: 301));
    expect(wallet.calls.last.priority, MinotariTransactionPriority.fast);
    output.cryptoAmount = '';
    await tester.pump(const Duration(milliseconds: 301));
    expect(wallet.calls.length, 2);
    expect(output.estimatedFee.amount, BigInt.zero);
  });
  testWidgets('out of order replies cannot replace the fee for a later amount', (tester) async {
    output = Output(wallet, _AppStore(settings), FiatConversionStore(),
        ([CryptoCurrency? _]) => CryptoCurrency.xtm);
    final first = Completer<FeeEstimate>();
    wallet.estimate = (amount) =>
        amount == BigInt.from(1000000) ? first.future : Future.value(quote(amount, fee: 700));
    output.cryptoAmount = '1';
    await tester.pump(const Duration(milliseconds: 301));
    output.cryptoAmount = '2';
    await tester.pump(const Duration(milliseconds: 301));
    expect(output.estimatedFee.amount, BigInt.from(700));
    first.complete(quote(BigInt.from(1000000), fee: 100));
    await tester.pump();
    expect(output.estimatedFee.amount, BigInt.from(700));
  });
  testWidgets('clearing amount before a pending response cannot restore an old fee',
      (tester) async {
    output = Output(wallet, _AppStore(settings), FiatConversionStore(),
        ([CryptoCurrency? _]) => CryptoCurrency.xtm);
    final delayed = Completer<FeeEstimate>();
    wallet.estimate = (_) => delayed.future;
    output.cryptoAmount = '1';
    await tester.pump(const Duration(milliseconds: 301));
    output.cryptoAmount = '';
    delayed.complete(quote(BigInt.from(1000000)));
    await tester.pump();
    expect(output.estimatedFee.amount, BigInt.zero);
    await tester.pump(const Duration(milliseconds: 301));
  });
  testWidgets('estimate errors clear the old displayed fee and never become an unhandled error',
      (tester) async {
    output = Output(wallet, _AppStore(settings), FiatConversionStore(),
        ([CryptoCurrency? _]) => CryptoCurrency.xtm);
    output.cryptoAmount = '1';
    await tester.pump(const Duration(milliseconds: 301));
    expect(output.estimatedFee.amount, BigInt.from(500));
    wallet.estimate = (_) async => throw StateError('synthetic RPC failure');
    output.note = 'changed note';
    expect(output.estimatedFee.amount, BigInt.zero);
    await tester.pump(const Duration(milliseconds: 301));
    expect(output.estimatedFee.amount, BigInt.zero);
  });
  testWidgets('adapter preserves priority in transaction credentials', (tester) async {
    output = Output(wallet, _AppStore(settings), FiatConversionStore(),
        ([CryptoCurrency? _]) => CryptoCurrency.xtm);
    output.cryptoAmount = '1';
    output.address = 'synthetic';
    output.note = 'payment';
    final credentials = minotari!.createMinotariTransactionCredentials([output],
        priority: MinotariTransactionPriority.fast) as MinotariTransactionCredentials;
    expect(credentials.priority, MinotariTransactionPriority.fast);
    expect(
        credentials.outputs.single.cryptoAmount, Money(BigInt.from(1000000), CryptoCurrency.xtm));
    expect(credentials.outputs.single.note, 'payment');
    await tester.pump(const Duration(milliseconds: 301));
  });
}
