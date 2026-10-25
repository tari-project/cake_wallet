import 'package:cake_wallet/view_model/send/output.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_credentials.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_service.dart';
import 'package:cw_minotari/minotari_amount_format.dart';
import 'package:cw_minotari/minotari_transaction_priority.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/minotari_wallet_service.dart';
import 'package:cw_minotari/pending_minotari_transaction.dart';
import 'package:cw_minotari/minotari_runtime.dart';

part 'cw_minotari.dart';

Minotari? minotari = CWMinotari();

abstract class Minotari {
  WalletService createMinotariWalletService();
  Future<bool> beginBackgroundSync();
  Future<void> endBackgroundSync();

  WalletCredentials createMinotariNewWalletCredentials({
    required String name,
    String? password,
    String? passphrase,
    WalletInfo? walletInfo,
  });

  WalletCredentials createMinotariRestoreWalletFromSeedCredentials({
    required String name,
    required String password,
    required String mnemonic,
    required int height,
    String? passphrase,
    WalletInfo? walletInfo,
  });

  WalletCredentials createMinotariRestoreWalletFromKeysCredentials({
    required String name,
    required String password,
    required String viewPrivateKeyHex,
    required String spendPublicKeyHex,
    required int birthday,
    String? passphrase,
    WalletInfo? walletInfo,
  });

  Money? getMinotariEstimatedFee(Object wallet);

  Future<Money> estimateMinotariPaymentFee(
    Object wallet, {
    required Money amount,
    TransactionPriority? priority,
    String? paymentId,
  });

  List<TransactionPriority> getTransactionPriorities();
  TransactionPriority deserializeMinotariTransactionPriority({required int raw});
  TransactionPriority getMinotariTransactionPriorityMedium();
  TransactionPriority getMinotariTransactionPrioritySlow();

  Object createMinotariTransactionCredentials(List<Output> outputs,
      {TransactionPriority? priority});

  Object createMinotariTransactionCredentialsRaw(List<OutputInfo> outputs,
      {TransactionPriority? priority});

  int getHeightByDate({required DateTime date});
  Future<int> getCurrentHeight();

  Map<String, String> getKeys(Object wallet);
  int? getRestoreHeight(Object wallet);

  String formatterMinotariAmountToString({required int amount});
  double formatterMinotariAmountToDouble({required int amount});
  int formatterMinotariParseAmount({required String amount});
}
