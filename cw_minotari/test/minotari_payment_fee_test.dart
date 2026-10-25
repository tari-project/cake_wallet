import 'dart:async';
import 'dart:io';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/minotari_transaction_priority.dart';
import 'package:cw_minotari/pending_minotari_transaction.dart';
import 'package:cw_minotari/src/rust/api/balance.dart';
import 'package:cw_minotari/src/rust/api/fee.dart';
import 'package:cw_minotari/src/rust/api/network.dart';
import 'package:cw_minotari/src/rust/api/send_transaction.dart';
import 'package:cw_minotari/src/rust/api/transactions.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Info extends Fake implements WalletInfo {
  @override
  bool get isRecovery => false;
  @override
  String get name => 'synthetic-fee-test';
  @override
  WalletType get type => WalletType.minotari;
  @override
  String? get network => 'mainNet';
  @override
  Future<Set<String>> getUsedAddresses() async => {};
  @override
  Future<Set<String>> getHiddenAddresses() async => {};
  @override
  Future<Set<String>> getManualAddresses() async => {};
}

class _Encryption extends Fake implements EncryptionFileUtils {}

class _Api extends Fake implements RustLibApi {
  final requests = <({BigInt amount, FeePriority priority, String url, String? note})>[];
  Future<FeeEstimate> Function(BigInt, FeePriority, String?)? estimate;
  SendTransactionDetails? sent;
  BigInt? sentRate;
  BigInt? sentMaximum;
  @override
  Future<void> crateApiDbInitializeDatabase({required String path}) async {}
  @override
  Future<void> crateApiScannerStopScan() async {}
  @override
  Future<String> crateApiAddressGetAddress(
          {required String walletName, String? passphrase, TariNetwork? network}) async =>
      'synthetic-address';
  @override
  Future<AccountBalanceDto> crateApiBalanceGetBalance({required String walletName}) async =>
      AccountBalanceDto(
          total: BigInt.from(10000000),
          available: BigInt.from(10000000),
          locked: BigInt.zero,
          unconfirmed: BigInt.zero);
  @override
  Future<List<DisplayedTransactionDto>> crateApiTransactionsGetTransactions(
          {required String walletName, required int limit, required int offset}) async =>
      [];
  @override
  Future<FeeEstimate> crateApiFeeEstimatePaymentFee(
      {required BigInt amount,
      required FeePriority priority,
      required String baseUrl,
      required String walletName,
      String? paymentId}) {
    requests.add((amount: amount, priority: priority, url: baseUrl, note: paymentId));
    return estimate?.call(amount, priority, paymentId) ?? Future.value(quote(amount));
  }

  @override
  Stream<SendTransactionEvent> crateApiSendTransactionSendTransactionWithFee(
      {required SendTransactionDetails details,
      required BigInt feePerGram,
      required BigInt maxFee}) async* {
    sent = details;
    sentRate = feePerGram;
    sentMaximum = maxFee;
    yield const SendTransactionEvent(stage: TransactionStage.completed, details: 'synthetic-tx-id');
  }
}

FeeEstimate quote(BigInt amount, {int fee = 500, int rate = 5}) => FeeEstimate(
      estimatedFee: BigInt.from(fee),
      totalAmountRequired: amount + BigInt.from(fee),
      feePerGram: BigInt.from(rate),
      inputCount: BigInt.one,
    );
OutputInfo output({bool all = false, BigInt? amount, String note = ''}) => OutputInfo(
      address: 'synthetic-recipient',
      sendAll: all,
      isParsedAddress: false,
      cryptoAmount: Money(amount ?? BigInt.from(1234567), CryptoCurrency.xtm),
      note: note,
    );
Node node([String uri = 'rpc.example:443']) =>
    Node(uri: uri, type: WalletType.minotari, useSSL: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  late Directory root;
  late MinotariWallet wallet;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('xtm-fee-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    RustLib.initMock(api: api);
  });
  tearDownAll(() async {
    RustLib.dispose();
    await root.delete(recursive: true);
  });
  setUp(() async {
    api.requests.clear();
    api.estimate = null;
    api.sent = null;
    api.sentRate = null;
    api.sentMaximum = null;
    // Synthetic words are never sent to real native signing in these mock tests.
    wallet = MinotariWallet(_Info(), DerivationInfo(),
        password: '',
        mnemonic: List.filled(24, 'synthetic').join(' '),
        encryptionFileUtils: _Encryption());
    await wallet.init();
    await wallet.connectToNode(node: node());
  });
  tearDown(() => wallet.close());

  test('amount, priority, selected URL and UTF8 note reach native payment estimate', () async {
    final amount = BigInt.from(1234567);
    final result = await wallet.estimatePaymentFee(
        amount: amount, priority: MinotariTransactionPriority.fast, paymentId: 'invoice-я');
    expect(api.requests.single, (
      amount: amount,
      priority: FeePriority.fast,
      url: 'https://rpc.example',
      note: 'invoice-я'
    ));
    expect(wallet.cachedFeeEstimate, same(result));
    expect(wallet.calculateEstimatedFee(MinotariTransactionPriority.fast, 1234567), 500);
    expect(wallet.calculateEstimatedFee(MinotariTransactionPriority.fast, 1234568), 0);
    expect(wallet.calculateEstimatedFee(MinotariTransactionPriority.slow, 1234567), 0);
  });
  test('amount-less generic refresh never estimates a fictitious zero amount', () async {
    await wallet.updateEstimatedFeesParams(MinotariTransactionPriority.fast);
    expect(api.requests, isEmpty);
  });
  test('late success cannot replace the latest payment quote', () async {
    final old = Completer<FeeEstimate>();
    api.estimate = (amount, priority, note) =>
        amount == BigInt.one ? old.future : Future.value(quote(amount, fee: 600));
    final first = wallet.estimatePaymentFee(amount: BigInt.one);
    final firstError = expectLater(first, throwsStateError);
    await wallet.estimatePaymentFee(amount: BigInt.two);
    old.complete(quote(BigInt.one));
    await firstError;
    expect(wallet.cachedFeeEstimate!.estimatedFee, BigInt.from(600));
  });
  test('identical concurrent preview does not cancel confirmation or overwrite latest cache',
      () async {
    final first = Completer<FeeEstimate>();
    var calls = 0;
    api.estimate = (amount, priority, note) =>
        ++calls == 1 ? first.future : Future.value(quote(amount, fee: 600));
    final confirmation = wallet.createTransaction(MinotariTransactionCredentials([output()]));
    await Future<void>.delayed(Duration.zero);
    await wallet.estimatePaymentFee(amount: BigInt.from(1234567));
    first.complete(quote(BigInt.from(1234567), fee: 500));
    final pending = await confirmation;
    expect(pending.fee.amount, BigInt.from(500));
    expect(wallet.cachedFeeEstimate!.estimatedFee, BigInt.from(600));
    await pending.commit();
    expect(api.sentMaximum, BigInt.from(500));
  });

  test('late failure cannot invalidate a newer successful quote', () async {
    final old = Completer<FeeEstimate>();
    api.estimate =
        (amount, priority, note) => amount == BigInt.one ? old.future : Future.value(quote(amount));
    final first = wallet.estimatePaymentFee(amount: BigInt.one);
    final firstError = expectLater(first, throwsStateError);
    await wallet.estimatePaymentFee(amount: BigInt.two);
    old.completeError(StateError('old RPC failure'));
    await firstError;
    expect(wallet.cachedFeeEstimate!.totalAmountRequired, BigInt.from(502));
  });
  test('failed latest estimate clears stale cache and blocks confirmation', () async {
    await wallet.estimatePaymentFee(amount: BigInt.one);
    api.estimate = (_, __, ___) async => throw StateError('RPC failed');
    await expectLater(
        wallet.createTransaction(MinotariTransactionCredentials([output()])), throwsStateError);
    expect(wallet.cachedFeeEstimate, isNull);
    expect(api.sent, isNull);
  });
  test('confirmation refreshes the quote; commit uses its immutable amount, rate and cap',
      () async {
    await wallet.estimatePaymentFee(amount: BigInt.one);
    api.estimate = (amount, priority, note) async => quote(amount, fee: 700, rate: 10);
    final pending = await wallet.createTransaction(MinotariTransactionCredentials(
        [output(note: 'invoice')],
        priority: MinotariTransactionPriority.fast));
    expect(api.sent, isNull);
    expect(pending.fee.amount, BigInt.from(700));
    // A later preview must not alter the user's already confirmed payment.
    api.estimate = (amount, priority, note) async => quote(amount, fee: 100, rate: 1);
    await wallet.estimatePaymentFee(amount: BigInt.two);
    await pending.commit();
    expect(api.sent!.amount, BigInt.from(1234567));
    expect(api.sent!.paymentId, 'invoice');
    expect(api.sentRate, BigInt.from(10));
    expect(api.sentMaximum, BigInt.from(700));
    expect(pending.id, 'synthetic-tx-id');
  });
  test('node changes invalidate outstanding quotes and prevent stale pending send', () async {
    final pending = await wallet.createTransaction(MinotariTransactionCredentials([output()]));
    await wallet.connectToNode(node: node('another.example:443'));
    expect(wallet.cachedFeeEstimate, isNull);
    await expectLater(pending.commit(), throwsStateError);
    expect(api.sent, isNull);
  });
  test('close invalidates an in-flight fee response', () async {
    final delayed = Completer<FeeEstimate>();
    api.estimate = (_, __, ___) => delayed.future;
    final future = wallet.estimatePaymentFee(amount: BigInt.one);
    final error = expectLater(future, throwsStateError);
    await wallet.close();
    delayed.complete(quote(BigInt.one));
    await error;
    expect(wallet.cachedFeeEstimate, isNull);
  });
  test('invalid amounts and unsupported Send All never reach native send', () async {
    for (final amount in [BigInt.zero, -BigInt.one, BigInt.one << 64]) {
      await expectLater(wallet.estimatePaymentFee(amount: amount), throwsArgumentError);
    }
    await expectLater(wallet.createTransaction(MinotariTransactionCredentials([output(all: true)])),
        throwsUnsupportedError);
    await expectLater(
        wallet.createTransaction(MinotariTransactionCredentials([output(), output()])),
        throwsException);
    expect(api.requests, isEmpty);
    expect(api.sent, isNull);
  });
  test('invalid fee DTO is rejected rather than confirmed as zero', () async {
    api.estimate = (amount, _, __) async => quote(amount, fee: 0);
    await expectLater(
        wallet.createTransaction(MinotariTransactionCredentials([output()])), throwsStateError);
    expect(api.sent, isNull);
  });
}
