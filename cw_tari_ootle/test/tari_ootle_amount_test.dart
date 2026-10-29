import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_tari_ootle/tari_ootle_balance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TARI has 6 decimals: µT from the bridge format as TARI', () {
    expect(CryptoCurrency.tari.decimals, 6);
    expect(Money(BigInt.from(1), CryptoCurrency.tari).toString(), '0.000001');
    expect(Money(BigInt.from(1500000), CryptoCurrency.tari).toString(), '1.5');
    expect(Money(BigInt.from(1000000000), CryptoCurrency.tari).toString(), '1000');
  });

  test('TARI entered by the user parses to exact µT', () {
    expect(Money.parse('1.5', CryptoCurrency.tari).amount, BigInt.from(1500000));
    expect(Money.parse('0.000001', CryptoCurrency.tari).amount, BigInt.one);
    expect(Money.parse('123456.654321', CryptoCurrency.tari).amount, BigInt.from(123456654321));
    expect(Money.tryParse('0.0000001', CryptoCurrency.tari), isNull);
  });

  test('balance keeps available and pending outgoing apart', () {
    final b = TariOotleBalance.fromMicro(
        available: BigInt.from(2500000), pendingOutgoing: BigInt.from(100000));
    expect(b.available.toString(), '2.5');
    expect(b.unavailable.toString(), '0.1');
  });
}
