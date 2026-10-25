part of 'minotari.dart';

class CWMinotari extends Minotari {
  @override
  Future<bool> beginBackgroundSync() => MinotariRuntime.instance.beginBackground();

  @override
  Future<void> endBackgroundSync() => MinotariRuntime.instance.endBackground();

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
    final minotariWallet = wallet as MinotariWallet;
    final feeEstimate = minotariWallet.cachedFeeEstimate;
    if (feeEstimate != null) {
      return Money(feeEstimate.estimatedFee, CryptoCurrency.xtm);
    } else {
      return null;
    }
  }

  @override
  Future<Money> estimateMinotariPaymentFee(
    Object wallet, {
    required Money amount,
    TransactionPriority? priority,
    String? paymentId,
  }) async {
    if (amount.currency != CryptoCurrency.xtm) {
      throw ArgumentError('Minotari fees require an XTM amount.');
    }
    final quote = await (wallet as MinotariWallet).estimatePaymentFee(
      amount: amount.amount,
      priority: priority,
      paymentId: paymentId,
    );
    return Money(quote.estimatedFee, CryptoCurrency.xtm);
  }

  @override
  List<TransactionPriority> getTransactionPriorities() => MinotariTransactionPriority.all;

  @override
  TransactionPriority deserializeMinotariTransactionPriority({required int raw}) =>
      MinotariTransactionPriority.deserialize(raw: raw);

  @override
  TransactionPriority getMinotariTransactionPriorityMedium() => MinotariTransactionPriority.medium;

  @override
  TransactionPriority getMinotariTransactionPrioritySlow() => MinotariTransactionPriority.slow;

  @override
  Object createMinotariTransactionCredentials(List<Output> outputs,
          {TransactionPriority? priority}) =>
      MinotariTransactionCredentials(
        outputs
            .map((out) => OutputInfo(
                  fiatAmount: out.fiatAmount,
                  cryptoAmount: out.cryptoAmountMoney,
                  address: out.address,
                  note: out.note,
                  sendAll: out.sendAll,
                  extractedAddress: out.extractedAddress,
                  isParsedAddress: out.isParsedAddress,
                  memo: out.memo,
                ))
            .toList(),
        priority: priority,
      );

  @override
  Object createMinotariTransactionCredentialsRaw(List<OutputInfo> outputs,
          {TransactionPriority? priority}) =>
      MinotariTransactionCredentials(outputs, priority: priority);

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
  int formatterMinotariParseAmount({required String amount}) => minotariParseAmount(amount: amount);
}
