import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';

class MinotariBalance extends Balance {
  final Money pendingIncoming;
  final Money pendingOutgoing;

  MinotariBalance({
    required int available,
    required int pendingIncoming,
    required int pendingOutgoing,
  })  : pendingIncoming = Money.fromInt(pendingIncoming, CryptoCurrency.xtm),
        pendingOutgoing = Money.fromInt(pendingOutgoing, CryptoCurrency.xtm),
        super(Money.fromInt(available, CryptoCurrency.xtm),
            Money.fromInt(pendingIncoming + pendingOutgoing, CryptoCurrency.xtm));

  String get formattedAvailableBalance => available.toString();

  String get formattedAdditionalBalance => (pendingIncoming + pendingOutgoing).toString();

  String get formattedUnAvailableBalance => pendingOutgoing.toString();

  String get formattedFullAvailableBalance => (available + pendingIncoming).toString();
}
