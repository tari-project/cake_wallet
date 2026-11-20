import 'package:cake_wallet/entities/transaction_description.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/src/screens/transaction_details/address_list_item.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/view_model/send/send_view_model.dart';
import 'package:cake_wallet/view_model/transaction_details_view_model.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:intl/date_symbol_data_local.dart';

class _App extends Mock implements AppStore {}

class _Settings extends Mock implements SettingsStore {}

class _Wallet extends Mock implements WalletBase {}

class _Addresses extends Mock implements WalletAddresses {}

class _Send extends Mock implements SendViewModel {}

class _Descriptions extends Mock implements Box<TransactionDescription> {}

void main() {
  setUpAll(() async {
    S.current = const S();
    await initializeDateFormatting('en');
  });
  List<AddressListItem> addresses(WalletType type,
      {String? counterparty, String savedAddress = 'saved-recipient'}) {
    final app = _App(), settings = _Settings(), wallet = _Wallet(), own = _Addresses();
    final descriptions = _Descriptions();
    when(() => app.settingsStore).thenReturn(settings);
    when(() => settings.languageCode).thenReturn('en');
    when(() => settings.shouldSaveRecipientAddress).thenReturn(true);
    when(() => wallet.type).thenReturn(type);
    when(() => wallet.walletAddresses).thenReturn(own);
    when(() => own.primaryAddress).thenReturn('our-address');
    when(() => descriptions.values).thenReturn([
      TransactionDescription(id: 'send-id', recipientAddress: savedAddress),
    ]);
    final tx = MinotariTransactionInfo(
        id: 'send-id',
        amount: Money.fromInt(1000000, CryptoCurrency.xtm),
        date: DateTime.utc(2026),
        direction: TransactionDirection.outgoing,
        isPending: false,
        height: 42,
        confirmations: 3);
    if (counterparty != null)
      tx.additionalInfo.addAll({
        'counterpartyAddress': counterparty,
        'counterpartyEmoji': '🦊',
      });
    final vm = TransactionDetailsViewModel(
        transactionInfo: tx,
        transactionDescriptionBox: descriptions,
        wallet: wallet,
        appStore: app,
        sendViewModel: _Send());
    return vm.items.whereType<AddressListItem>().toList();
  }

  test('a real XTM send shows one native recipient instead of a saved duplicate', () {
    final rows = addresses(WalletType.minotari,
        counterparty: 'native-recipient', savedAddress: 'native-recipient');
    expect(rows.map((r) => r.value).toList(), ['native-recipient']);
  });
  test('old XTM history without a native recipient keeps its saved address', () {
    expect(addresses(WalletType.minotari).single.value, 'saved-recipient');
    expect(addresses(WalletType.minotari, counterparty: '').single.value, 'saved-recipient');
  });
  test('native XTM metadata does not suppress the saved address for other currencies', () {
    expect(addresses(WalletType.nano, counterparty: 'native-recipient').single.value,
        'saved-recipient');
  });
  test('batch sends retain additional saved recipients beyond the native first counterparty', () {
    final rows = addresses(WalletType.minotari,
        counterparty: 'native-recipient', savedAddress: 'native-recipient, second-recipient');
    expect(rows.map((row) => row.value).toList(),
        ['native-recipient', 'native-recipient, second-recipient']);
  });
}
