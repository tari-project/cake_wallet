part of 'minotari.dart';

class CWMinotari extends Minotari {
  @override
  WalletService createMinotariWalletService() => MinotariWalletService();

  @override
  WalletCredentials createMinotariNewWalletCredentials({
    required String name,
    String? password,
    String? passphrase,
    WalletInfo? walletInfo,
  }) =>
      MinotariNewWalletCredentials(
        name: name,
        password: password,
        passphrase: passphrase,
        walletInfo: walletInfo,
      );

  @override
  WalletCredentials createMinotariRestoreWalletFromSeedCredentials({
    required String name,
    required String password,
    required String mnemonic,
    required int height,
    String? passphrase,
    WalletInfo? walletInfo,
  }) =>
      MinotariRestoreWalletFromSeedCredentials(
        name: name,
        password: password,
        mnemonic: mnemonic,
        height: height,
        passphrase: passphrase,
        walletInfo: walletInfo,
      );

  @override
  WalletCredentials createMinotariRestoreWalletFromKeysCredentials({
    required String name,
    required String password,
    required String viewPrivateKeyHex,
    required String spendPublicKeyHex,
    required int birthday,
    String? passphrase,
    WalletInfo? walletInfo,
  }) =>
      MinotariRestoreWalletFromKeysCredentials(
        name: name,
        password: password,
        viewPrivateKeyHex: viewPrivateKeyHex,
        spendPublicKeyHex: spendPublicKeyHex,
        birthday: birthday,
        passphrase: passphrase,
        walletInfo: walletInfo,
      );

  @override
  Money? getMinotariEstimatedFee(Object wallet) {
    final feeEstimate = (wallet as MinotariWallet).cachedFeeEstimate;
    return feeEstimate == null ? null : Money(feeEstimate.estimatedFee, CryptoCurrency.xtm);
  }

  @override
  List<TransactionPriority> getTransactionPriorities() =>
      MinotariTransactionPriority.all;

  @override
  TransactionPriority deserializeMinotariTransactionPriority({required int raw}) =>
      MinotariTransactionPriority.deserialize(raw: raw);

  @override
  TransactionPriority getMinotariTransactionPriorityMedium() =>
      MinotariTransactionPriority.medium;

  @override
  TransactionPriority getMinotariTransactionPrioritySlow() =>
      MinotariTransactionPriority.slow;

  @override
  Object createMinotariTransactionCredentials(List<Output> outputs) =>
      MinotariTransactionCredentials(
        outputs.map((out) => OutputInfo(
          fiatAmount: out.fiatAmount,
          cryptoAmount: out.cryptoAmountMoney,
          address: out.address,
          note: out.note,
          sendAll: out.sendAll,
          extractedAddress: out.extractedAddress,
          isParsedAddress: out.isParsedAddress,
        )).toList(),
      );

  @override
  Object createMinotariTransactionCredentialsRaw(List<OutputInfo> outputs) =>
      MinotariTransactionCredentials(outputs);

  @override
  int getHeightByDate({required DateTime date}) {
    // TODO: Implement proper block height calculation from date
    return 0;
  }

  @override
  Future<int> getCurrentHeight() async {
    // TODO: Get current blockchain height from connected node
    return 0;
  }

  @override
  Map<String, String> getKeys(Object wallet) {
    final minotariWallet = wallet as MinotariWallet;
    final keys = <String, String>{};

    final seed = minotariWallet.seed;
    if (seed != null) {
      keys['seed'] = seed;
    }

    final viewKey = minotariWallet.viewPrivateKeyHex;
    if (viewKey != null) {
      keys['viewPrivateKey'] = viewKey;
    }

    final spendKey = minotariWallet.spendPublicKeyHex;
    if (spendKey != null) {
      keys['spendPublicKey'] = spendKey;
    }

    return keys;
  }

  @override
  int? getRestoreHeight(Object wallet) {
    final minotariWallet = wallet as MinotariWallet;
    // Return the wallet's restore height from walletInfo
    return minotariWallet.walletInfo.restoreHeight;
  }

  @override
  String formatterMinotariAmountToString({required int amount}) =>
      minotariAmountToString(amount: amount);

  @override
  double formatterMinotariAmountToDouble({required int amount}) =>
      minotariAmountToDouble(amount: amount);

  @override
  int formatterMinotariParseAmount({required String amount}) =>
      minotariParseAmount(amount: amount);

  @override
  Future<int> estimateBurnFee(Object wallet, int amount) =>
      (wallet as MinotariWallet).estimateBurnFee(amount);

  @override
  Stream<String> burnToL2(Object wallet, {required String claimPublicKey, required int amount}) =>
      (wallet as MinotariWallet)
          .burnToL2(claimPublicKey: claimPublicKey, amount: amount)
          .map((event) => switch (event) {
                BurnEvent_Stage(:final field0) => field0.details,
                BurnEvent_Recorded(:final field0) => field0.acceptedByNode
                    ? 'Burn broadcast.'
                    : 'Burn recorded but the node has not accepted it yet'
                        '${field0.nodeReason == null ? '' : ' (${field0.nodeReason})'}. '
                        'The wallet rebroadcasts it while it syncs.',
              });

  @override
  Future<List<MinotariBurn>> getBurns(Object wallet) async =>
      (await (wallet as MinotariWallet).getBurnProofs())
          .map((p) => MinotariBurn(
                commitment: p.commitment,
                claimPublicKey: p.claimPublicKey,
                amount: p.amount.toInt(),
                isReady: p.status == BurnProofStatus.ready,
                pendingReason: p.pendingReason,
              ))
          .toList();
}
