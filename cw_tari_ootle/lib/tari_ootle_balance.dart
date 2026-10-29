import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';

class TariOotleBalance extends Balance {
  /// [pendingOutgoing] is value locked by sends that have not finalized yet.
  TariOotleBalance({required Money available, required Money pendingOutgoing})
      : super(available, pendingOutgoing);

  // TODO: the bridge also reports `revealed` (TARI in the account's public vault, shown but not
  // spent by v1). Balance has no slot for it yet; surface it once Cake's balance card can.

  factory TariOotleBalance.fromMicro({required BigInt available, required BigInt pendingOutgoing}) =>
      TariOotleBalance(
        available: Money(available, CryptoCurrency.tari),
        pendingOutgoing: Money(pendingOutgoing, CryptoCurrency.tari),
      );

  factory TariOotleBalance.zero() =>
      TariOotleBalance.fromMicro(available: BigInt.zero, pendingOutgoing: BigInt.zero);
}
