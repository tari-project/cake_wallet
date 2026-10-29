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

  @override
  Future<String> claimPublicKeyFromAddress(String address) => tariOotleClaimPublicKey(address);

  @override
  Future<String> addressFromSeed(String seedWords, String? networkName) =>
      tariOotleAddressFromSeed(seedWords, tariOotleNetworkByName(networkName));

  @override
  Future<bool> validateAddress(String address, String? networkName) =>
      tariOotleValidateAddress(address, tariOotleNetworkByName(networkName));

  @override
  String? claimPublicKey(Object wallet) => (wallet as TariOotleWallet).claimPublicKey;

  @override
  Future<void> addBurnProof(Object wallet, String proofJson) =>
      (wallet as TariOotleWallet).addBurnProof(proofJson);

  @override
  Future<List<TariOotleClaim>> getClaims(Object wallet) async =>
      (await (wallet as TariOotleWallet).getClaims())
          .map((c) => TariOotleClaim(
                id: c.id,
                amount: Money(c.amount, CryptoCurrency.tari),
                status: c.status.name,
                minedInEpoch: c.minedInEpoch.toInt(),
                txId: c.txId,
                lastError: c.lastError,
              ))
          .toList();

  @override
  Stream<String> claimBurn(Object wallet, String claimId) async* {
    await for (final event in (wallet as TariOotleWallet).claimBurn(claimId)) {
      switch (event) {
        case SendEvent_Submitted(:final txId):
          yield 'Submitted $txId';
        case SendEvent_Completed(:final txId):
          yield 'Claimed in $txId';
        case SendEvent_Failed(:final message):
          throw Exception(message);
      }
    }
  }

  @override
  Future<int> currentEpoch(Object wallet) => (wallet as TariOotleWallet).currentEpoch();
}
