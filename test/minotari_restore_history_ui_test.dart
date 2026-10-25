import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/view_model/dashboard/balance_view_model.dart';
import 'package:cake_wallet/view_model/dashboard/transaction_list_item.dart';
import 'package:cake_wallet/view_model/transaction_details_view_model.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Fake implements AppStore {}

class _Wallet extends Fake implements WalletBase {
  _Wallet(this.type);
  @override
  final WalletType type;
}

class _Balance extends Fake implements BalanceViewModel {
  _Balance(this.wallet);
  @override
  final WalletBase wallet;
}

class _Details extends Fake implements TransactionDetailsViewModelBase {
  _Details(this.wallet, this.transactionInfo);
  @override
  final WalletBase wallet;
  @override
  final TransactionInfo transactionInfo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MinotariTransactionInfo tx(TransactionDirection direction, {bool restoring = true}) {
    final info = MinotariTransactionInfo(
        id: 'synthetic',
        amount: 25000000,
        fee: 700,
        date: DateTime.utc(2026, 10, 24),
        direction: direction,
        isPending: true,
        height: 100);
    info.additionalInfo['restoringHistory'] = restoring;
    info.additionalInfo['status'] = 'unconfirmed';
    return info;
  }

  TransactionListItem item(TransactionInfo info, {WalletType type = WalletType.minotari}) =>
      TransactionListItem(
          transaction: info,
          balanceViewModel: _Balance(_Wallet(type)),
          appStore: _App(),
          key: ValueKey(info.id));

  for (final locale in ['en', 'ru']) {
    test('restore list and details use localized Sent/Received in $locale', () async {
      await S.delegate.load(Locale(locale));
      final status = TxDetailRowDefinition.defs
          .firstWhere((r) => r.keyString == 'standard_list_item_transaction_details_status_key');
      final confirmations = TxDetailRowDefinition.defs
          .firstWhere((r) => r.keyString == 'standard_list_item_transaction_confirmations_key');
      for (final direction in TransactionDirection.values) {
        final info = tx(direction);
        final expected =
            direction == TransactionDirection.incoming ? S.current.received : S.current.sent;
        expect(item(info).formattedTitle, expected);
        expect(info.isPending, isTrue);
        final details = _Details(_Wallet(WalletType.minotari), info);
        expect(status.valueGetter(details), expected);
        expect(confirmations.applicable(details), isFalse);
        info.additionalInfo['restoringHistory'] = false;
        expect(
            item(info).formattedTitle,
            contains(direction == TransactionDirection.incoming
                ? S.current.receiving
                : S.current.sending));
        expect(item(info).formattedTitle, contains('(0/3)'));
        expect(confirmations.applicable(details), isTrue);
      }
    });
  }
  test('ordinary XTM pending and special statuses are preserved', () async {
    await S.delegate.load(const Locale('en'));
    final info = tx(TransactionDirection.incoming, restoring: false);
    expect(item(info).formattedTitle, startsWith('Receiving'));
    expect(item(info).formattedTitle, contains('(0/3)'));
    info.additionalInfo['restoringHistory'] = true;
    for (final status in ['Locked', 'Rejected', 'Cancelled', 'Reorganized']) {
      info.additionalInfo['historyStatus'] = status;
      expect(item(info).formattedTitle, status);
    }
  });
  test('the XTM preview flag has no effect on another wallet type', () async {
    await S.delegate.load(const Locale('en'));
    final info = tx(TransactionDirection.incoming);
    expect(item(info, type: WalletType.bitcoin).formattedTitle, startsWith('Receiving'));
    expect(item(info, type: WalletType.bitcoin).formattedTitle, isNot('Received'));
  });
}
