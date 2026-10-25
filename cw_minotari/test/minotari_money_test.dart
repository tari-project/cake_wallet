import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_minotari/minotari_balance.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:cw_minotari/pending_minotari_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core balance exposes XTM values in microTari', () {
    final Balance balance = MinotariBalance(
      available: 1234567,
      pendingIncoming: 2,
      pendingOutgoing: 3,
    );
    expect(balance.available, Money.parse('1.234567', CryptoCurrency.xtm));
    expect(balance.unavailable, Money.parse('0.000005', CryptoCurrency.xtm));
  });

  test('transaction history preserves large amounts and one microTari fees', () {
    final TransactionInfo transaction = MinotariTransactionInfo(
      id: 'test-transaction',
      amount: 9007199254740993,
      fee: 1,
      date: DateTime.utc(2026),
      direction: TransactionDirection.incoming,
      isPending: false,
    );
    expect(transaction.amount.amount, BigInt.parse('9007199254740993'));
    expect(transaction.amount.toString(), '9007199254.740993');
    expect(transaction.fee, Money.parse('0.000001', CryptoCurrency.xtm));
  });

  test('pending transaction exposes amounts through the core Money API', () {
    final PendingTransaction transaction = PendingMinotariTransaction(
      amount: Money.parse('0.000001', CryptoCurrency.xtm),
      fee: Money.parse('0.000002', CryptoCurrency.xtm),
      recipientAddress: 'test-recipient',
      sendTransaction: () async => 'test-transaction',
    );
    expect(transaction.amount.amount, BigInt.one);
    expect(transaction.fee.amount, BigInt.two);
    expect(transaction.amountFormatted, '0.000001 XTM');
    expect(transaction.feeFormattedValue, '0.000002');
  });
}
