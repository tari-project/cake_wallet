import 'package:cake_wallet/bitcoin/bitcoin.dart';
import 'package:cake_wallet/core/seed_validator.dart';
import 'package:cake_wallet/utils/language_list.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Minotari restore can load its English word list without Bitcoin', () {
    final bitcoinImplementation = bitcoin;
    bitcoin = null;
    addTearDown(() => bitcoin = bitcoinImplementation);

    final words = SeedValidator.getWordList(
      type: WalletType.minotari,
      language: LanguageList.english,
    );

    expect(words, hasLength(2048));
    expect(words.first, 'abandon');
    expect(words.last, 'zoo');
  });
}
