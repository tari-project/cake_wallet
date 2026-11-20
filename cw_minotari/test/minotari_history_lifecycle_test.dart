import 'dart:async';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:flutter_test/flutter_test.dart';

class _Files extends EncryptionFileUtils {
  Future<void> write(
      {required String path, required String password, required String data}) async {}
  Future<String> read({required String path, required String password}) async => '';
}

class _Info implements WalletInfo {
  Future<Set<String>> getUsedAddresses() async => {};
  Future<Set<String>> getHiddenAddresses() async => {};
  Future<Set<String>> getManualAddresses() async => {};
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Wallet extends MinotariWallet {
  _Wallet()
      : super(_Info(), DerivationInfo(),
            password: 'test', dbPassphrase: 'test', encryptionFileUtils: _Files());
  final reads = <Completer<Map<String, MinotariTransactionInfo>>>[];
  @override
  Future<Map<String, MinotariTransactionInfo>> fetchTransactions() {
    final read = Completer<Map<String, MinotariTransactionInfo>>();
    reads.add(read);
    return read.future;
  }
}

Map<String, MinotariTransactionInfo> _rows(String id) => {
      id: MinotariTransactionInfo(
          id: id,
          amount: Money.fromInt(1, CryptoCurrency.xtm),
          date: DateTime.utc(2026),
          direction: TransactionDirection.incoming,
          isPending: false),
    };
void main() {
  test('overlapping full reloads serialize; the later request publishes last', () async {
    final w = _Wallet();
    final first = w.updateTransactions();
    await Future<void>.delayed(Duration.zero);
    expect(w.reads, hasLength(1));
    final second = w.updateTransactions();
    await Future<void>.delayed(Duration.zero);
    expect(w.reads, hasLength(1));
    w.reads[0].complete(_rows('old'));
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(w.reads, hasLength(2));
    w.reads[1].complete(_rows('new'));
    await second;
    expect(w.transactionHistory.transactions.keys, ['new']);
    await w.close();
  });
  test('close discards an in-flight history read and queued reload', () async {
    final w = _Wallet();
    w.transactionHistory.transactions.addAll(_rows('kept'));
    final first = w.updateTransactions();
    await Future<void>.delayed(Duration.zero);
    final second = w.updateTransactions();
    await w.close();
    w.reads[0].complete(_rows('stale'));
    await first;
    await second;
    expect(w.reads, hasLength(1));
    expect(w.transactionHistory.transactions.keys, ['kept']);
  });
  test('a failed local read completes quietly and the next refresh still succeeds', () async {
    final w = _Wallet();
    final first = w.updateTransactions();
    final failed = expectLater(first, completes);
    await Future<void>.delayed(Duration.zero);
    final second = w.updateTransactions();
    w.reads[0].completeError(StateError('read failed'));
    await failed;
    await Future<void>.delayed(Duration.zero);
    expect(w.reads, hasLength(2));
    w.reads[1].complete(_rows('recovered'));
    await second;
    expect(w.transactionHistory.transactions.keys, ['recovered']);
    await w.close();
  });
}
