part of 'tari_ootle.dart';

class CWTariOotle extends TariOotle {
  @override
  WalletService createTariOotleWalletService() => TariOotleWalletService();

  @override
  WalletCredentials createTariOotleNewWalletCredentials({
    required String name,
    String? password,
    WalletInfo? walletInfo,
  }) =>
      TariOotleNewWalletCredentials(name: name, password: password, walletInfo: walletInfo);

  @override
  WalletCredentials createTariOotleRestoreWalletFromSeedCredentials({
    required String name,
    required String password,
    required String mnemonic,
    WalletInfo? walletInfo,
  }) =>
      TariOotleRestoreWalletFromSeedCredentials(
          name: name, password: password, mnemonic: mnemonic, walletInfo: walletInfo);

  @override
  Object createTariOotleTransactionCredentials(List<Output> outputs) =>
      TariOotleTransactionCredentials(outputs
          .map((out) => OutputInfo(
                fiatAmount: out.fiatAmount,
                cryptoAmount: out.cryptoAmountMoney,
                address: out.address,
                note: out.note,
                memo: out.memo,
                sendAll: out.sendAll,
                extractedAddress: out.extractedAddress,
                isParsedAddress: out.isParsedAddress,
              ))
          .toList());

  @override
  Money? getTariOotleEstimatedFee(Object wallet) => (wallet as TariOotleWallet).estimatedFee;
}
