import "package:cake_wallet/core/execution_state.dart";
import "package:cake_wallet/core/new_wallet_arguments.dart";
import "package:cake_wallet/di.dart";
import "package:cake_wallet/minotari/minotari.dart";
import "package:cake_wallet/store/app_store.dart";
import "package:cake_wallet/view_model/restore/restore_mode.dart";
import "package:cake_wallet/view_model/wallet_creation_vm.dart";
import "package:cake_wallet/view_model/wallet_new_vm.dart";
import "package:cake_wallet/view_model/wallet_restore_view_model.dart";
import "package:cw_core/amount/money.dart";
import "package:cw_core/crypto_currency.dart";
import "package:cw_core/output_info.dart";
import "package:cw_core/sync_status.dart";
import "package:cw_core/transaction_direction.dart";
import "package:cw_core/wallet_base.dart";
import "package:cw_core/wallet_service.dart";
import "package:cw_core/wallet_type.dart";
import "package:flutter_test/flutter_test.dart";
import "package:integration_test/integration_test.dart";
import "package:mobx/mobx.dart";

import "../../core/app_launcher.dart";
import "../../core/test_config.dart";
import "../../core/test_wallets.dart";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The release library supports mainnet. The first create/restore flow generates
  // its own unfunded seed; a persistent fixture is only needed for the history flows.
  integrationTest("Minotari wallet flows", (tester) async {
    final integration = minotari;
    if (integration == null) {
      tester.printToConsole("Minotari is disabled in this build, skipped");
      return;
    }

    await AppLauncher(tester).launchApp(testKey: "minotari_test_app_key");

    final appStore = getIt.get<AppStore>();
    tester.printToConsole("Create a wallet");
    final newWalletVM =
        getIt.get<WalletNewVM>(param1: NewWalletArguments(type: WalletType.minotari));
    await newWalletVM.create();
    _expectCreated(newWalletVM);
    final created = appStore.wallet!;
    expect(created.walletInfo.network, "mainNet");
    expect(created.balance[CryptoCurrency.xtm]!.available.amount, BigInt.zero);
    final address = created.walletAddresses.address;
    final seed = await integration.getSeed(created);
    expect(seed, isNotNull);
    expect(seed!.split(" ").length, 24);

    tester.printToConsole("Restore the wallet just created and verify its balance");
    await _removeTestWallet(created);
    await _restore(WalletRestoreMode.seed, {
      "name": "xtm_restore_${DateTime.now().microsecondsSinceEpoch}",
      "seed": seed,
    });
    final unfundedRestore = appStore.wallet!;
    expect(unfundedRestore.walletAddresses.address, address);
    expect(unfundedRestore.balance[CryptoCurrency.xtm]!.available.amount, BigInt.zero);

    final fixtureSeed = TestWallets.seedFor(WalletType.minotari);
    if (fixtureSeed.trim().isEmpty) {
      tester.printToConsole("Minotari history fixture missing, create/restore checks passed");
      return;
    }

    tester.printToConsole("Restore from seed and check history presentation through completion");
    final missingPreviews = <String>{};
    final stopWatchingRestore = autorun((_) {
      final restored = appStore.wallet;
      if (restored == null ||
          restored.name != "minotari_seed_restore" ||
          !restored.walletInfo.isRecovery ||
          restored.syncStatus is SyncedSyncStatus) {
        return;
      }
      for (final tx in restored.transactionHistory.transactions.values) {
        if (tx.additionalInfo["status"] == "unconfirmed" &&
            (tx.height ?? 0) > 0 &&
            tx.additionalInfo["restoringHistory"] != true) {
          missingPreviews.add(tx.id);
        }
      }
    });
    try {
      await _restore(WalletRestoreMode.seed, {
        "name": "minotari_seed_restore",
        "seed": fixtureSeed,
      });
      final restored = appStore.wallet!;
      expect(restored.walletAddresses.address, TestWallets.receiveAddressFor(WalletType.minotari));
      await _waitForSynced(tester, restored);
      final deadline = DateTime.now().add(TestConfig.walletSyncBudget);
      while (restored.walletInfo.isRecovery && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(restored.walletInfo.isRecovery, isFalse);
      expect(missingPreviews, isEmpty,
          reason: "Committed block events must use the wallet recovery state for history previews");
      expect(
          restored.transactionHistory.transactions.values
              .every((tx) => tx.additionalInfo["restoringHistory"] == false),
          isTrue);
    } finally {
      stopWatchingRestore();
    }

    tester.printToConsole("Restore from spend and view keys");
    final restoreHeight = int.parse(TestWallets.minotariRestoreHeight);
    await _removeTestWallet(appStore.wallet!);
    await _restore(WalletRestoreMode.keys, {
      "name": "minotari_keys_restore",
      "viewKey": TestWallets.minotariViewKey,
      "spendKey": TestWallets.minotariSpendKey,
      "height": restoreHeight,
    });
    final wallet = appStore.wallet!;
    expect(wallet.walletAddresses.address, TestWallets.receiveAddressFor(WalletType.minotari));
    expect(wallet.canSend(), isTrue);

    tester.printToConsole("Sign and verify a message");
    const message = "Cake Wallet Minotari integration test";
    final signature = await wallet.signMessage(message);
    expect(await wallet.verifyMessage(message, signature), isTrue);
    expect(await wallet.verifyMessage("$message!", signature), isFalse);

    tester.printToConsole("Rescan from the restore height");
    await _waitForSynced(tester, wallet);
    await wallet.rescan(height: restoreHeight);
    await _waitForSynced(tester, wallet);

    if (TestConfig.shouldSpend("minotari")) {
      final recipient = TestWallets.minotariRecipientAddress;
      OutputInfo output({BigInt? amount}) => OutputInfo(
            address: recipient,
            sendAll: amount == null,
            isParsedAddress: false,
            cryptoAmount: Money(amount ?? BigInt.zero, CryptoCurrency.xtm),
          );

      tester.printToConsole("Send to two recipients");
      await _send(wallet, [output(amount: BigInt.from(1000)), output(amount: BigInt.from(2000))]);
      expect(
        wallet.transactionHistory.transactions.values
            .any((tx) => tx.isPending && tx.direction == TransactionDirection.outgoing),
        isTrue,
      );

      tester.printToConsole("Send all");
      await _send(wallet, [output()]);
      expect(wallet.balance[CryptoCurrency.xtm]!.available.amount, BigInt.zero);
    }

    tester.printToConsole("Change the password and reopen");
    const newPassword = "minotari-integration-password";
    await wallet.changePassword(newPassword);
    await wallet.close();
    final reopened = await getIt
        .get<WalletService>(param1: WalletType.minotari)
        .openWallet(wallet.name, newPassword);
    expect(reopened.walletAddresses.address, TestWallets.receiveAddressFor(WalletType.minotari));
    await reopened.close();
  });
}

// Minotari stores a unique fingerprint for each account in its shared database.
Future<void> _removeTestWallet(WalletBase wallet) async {
  await wallet.close();
  await getIt.get<WalletService>(param1: WalletType.minotari).remove(wallet.name);
}

Future<void> _restore(WalletRestoreMode mode, Map<String, dynamic> options) async {
  final restoreVM = getIt.get<WalletRestoreViewModel>(param1: WalletType.minotari);
  restoreVM.mode = mode;
  await restoreVM.create(options: options);
  _expectCreated(restoreVM);
}

void _expectCreated(WalletCreationVM viewModel) {
  final state = viewModel.state;
  expect(state, isA<ExecutedSuccessfullyState>(),
      reason: state is FailureState ? state.error : "$state");
}

Future<void> _send(WalletBase wallet, List<OutputInfo> outputs) async {
  final pending =
      await wallet.createTransaction(minotari!.createMinotariTransactionCredentialsRaw(outputs));
  await pending.commit();
}

Future<void> _waitForSynced(WidgetTester tester, WalletBase wallet) async {
  final endTime = DateTime.now().add(TestConfig.walletSyncBudget);
  while (wallet.syncStatus is! SyncedSyncStatus) {
    if (DateTime.now().isAfter(endTime)) {
      throw TestFailure("Minotari never synced, its status was ${wallet.syncStatus.runtimeType}");
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
}
