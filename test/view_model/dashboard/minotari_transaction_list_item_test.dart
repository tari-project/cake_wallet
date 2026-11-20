import 'dart:ui' as ui;

import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/src/widgets/cake_image_widget.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/view_model/dashboard/balance_view_model.dart';
import 'package:cake_wallet/view_model/dashboard/transaction_list_item.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/card_design.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/currency_for_wallet_type.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics/vector_graphics.dart';

class _Wallet implements WalletBase {
  _Wallet(this.type);
  final WalletType type;
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Balance implements BalanceViewModel {
  _Balance(WalletType type) : wallet = _Wallet(type);
  final WalletBase wallet;
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _App implements AppStore {
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() => S.current = const S());
  MinotariTransactionInfo tx({String status = 'unconfirmed', bool restoring = false}) {
    final tx = MinotariTransactionInfo(
      id: 'stable-id',
      amount: Money.fromInt(1000000, CryptoCurrency.xtm),
      date: DateTime.utc(2026),
      direction: TransactionDirection.incoming,
      isPending: true,
      confirmations: 1,
      height: 42,
      payrefs: [],
    );
    tx.additionalInfo.addAll({'status': status, 'restoringHistory': restoring});
    return tx;
  }

  TransactionListItem row(MinotariTransactionInfo tx, [WalletType type = WalletType.minotari]) =>
      TransactionListItem(
          transaction: tx,
          balanceViewModel: _Balance(type),
          appStore: _App(),
          key: const ValueKey('row'));

  test('a live pending XTM row visibly includes the three confirmation threshold', () {
    expect(row(tx()).formattedTitle, '${S.current.receiving}  (1/3)');
    expect(row(tx()).neededConfirmations, 3);
  });
  test('restore preview shows mined history while native pending data stays intact', () {
    final transaction = tx(restoring: true);
    expect(row(transaction).formattedTitle, S.current.received);
    expect(transaction.isPending, isTrue);
    expect(transaction.additionalInfo['status'], 'unconfirmed');
  });
  test('restore preview never hides locked or failed native statuses', () {
    for (final status in {
      'locked': S.current.tx_status_locked,
      'cancelled': S.current.tx_status_cancelled,
      'rejected': S.current.tx_status_rejected,
      'reorganized': S.current.tx_status_reorganized,
    }.entries) {
      expect(row(tx(status: status.key, restoring: true)).formattedTitle, status.value);
    }
  });
  test('XTM metadata does not affect other currencies pending titles', () {
    expect(row(tx(restoring: true), WalletType.monero).formattedTitle,
        '${S.current.receiving}  (1/10)');
    expect(row(tx(status: 'locked', restoring: true), WalletType.wownero).formattedTitle,
        '${S.current.receiving}  (1/3)');
    expect(row(tx(status: 'rejected', restoring: true), WalletType.bitcoin).formattedTitle,
        '${S.current.receiving}...');
  });
  test('XTM uses the flat logo on the balance card and the full logo in wallet lists', () {
    const currency = CryptoCurrency.xtm;
    expect(CardDesign.fromStyleSettings(null, currency).imagePath, currency.flatIconPath);
    expect(CardDesign.forCurrencyIcon(currency).imagePath, currency.flatIconPath);
    expect(getCryptoCurrencyIconForWalletListItem(WalletType.minotari), currency.iconPath);
    final fullColor = CardDesign.iconPathsForWalletType(currency)
        .singleWhere((option) => option.path == currency.iconPath);
    expect(fullColor.preColored, isTrue);
  });
  testWidgets('the tinted XTM header icon preserves the logo cutout', (tester) async {
    final path = CryptoCurrency.xtm.flatIconPath!;
    await tester.pumpWidget(MaterialApp(
      home: CakeImageWidget(imageUrl: path, color: Colors.blue),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      final compiledIcon = await vg.loadPicture(AssetBytesLoader('$path.vec'), null);
      addTearDown(compiledIcon.picture.dispose);
      final image = await compiledIcon.picture.toImage(250, 250);
      addTearDown(image.dispose);
      final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alphaAt(int x, int y) => pixels.getUint8(4 * (y * image.width + x) + 3);

      expect(alphaAt(25, 125), 255, reason: 'the badge background is opaque');
      expect(alphaAt(50, 120), 0, reason: 'the Minotari logo remains visible under a tint');
    });
  });
}
