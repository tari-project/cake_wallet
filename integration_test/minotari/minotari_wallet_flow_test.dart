import "dart:ffi" show Abi;
import "dart:io";

import "package:cake_wallet/di.dart";
import "package:cake_wallet/entities/preferences_key.dart";
import "package:cake_wallet/generated/i18n.dart";
import "package:cake_wallet/new-ui/widgets/coins_page/cards/balance_card.dart";
import "package:cake_wallet/routes.dart";
import "package:cake_wallet/store/app_store.dart";
import "package:cake_wallet/store/settings_store.dart";
import "package:cw_core/crypto_currency.dart";
import "package:cw_core/node.dart";
import "package:cw_core/pathForWallet.dart";
import "package:cw_core/root_dir.dart";
import "package:cw_core/wallet_base.dart";
import "package:cw_core/wallet_info.dart";
import "package:cw_core/wallet_service.dart";
import "package:cw_core/wallet_type.dart";
import "package:cw_minotari/minotari_wallet.dart";
import "package:cw_minotari/minotari_wallet_service.dart";
import "package:cw_minotari/src/rust/api/db.dart" as native_db;
import "package:flutter/material.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:integration_test/integration_test.dart";
import "package:path_provider/path_provider.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sqflite/sqflite.dart";

import "../components/common_test_constants.dart";
import "../components/common_test_flows.dart";
import "../fixtures/minotari_test_wallet.dart";
import "../robots/setup_pin_code_robot.dart";

class _MinotariFlows extends CommonTestFlows {
  _MinotariFlows(this.tester) : super(tester);
  final WidgetTester tester;

  @override
  Future<void> setupPinCodeForWallet(List<int> pin) async {
    if (Platform.isLinux) return; // Matches the shared flow: Linux has no PIN setup.
    final robot = SetupPinCodeRobot(tester);
    await robot.isSetupPinCodePage();
    await robot.enterPinCode(pin);
    await robot.enterPinCode(pin);
    // AlertWithOneAction currently doesn't forward its buttonKey to the rendered
    // action. Tap the actual localized confirmation instead, within this XTM suite.
    await tester.tap(find.text(S.current.ok));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey("welcome_page_create_new_wallet_button_key")), findsOneWidget);
  }
}

class _IsolatedPaths extends PathProviderPlatform {
  _IsolatedPaths(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
  @override
  Future<String> getApplicationSupportPath() async => root;
  @override
  Future<String> getTemporaryPath() async => root;
  @override
  Future<String> getLibraryPath() async => root;
  @override
  Future<String> getApplicationCachePath() async => root;
}

/// Test-only network configuration. The application/UI and native wallet remain real.
class _EsmeraldaService extends MinotariWalletService {
  @override
  Future<WalletBase> create(MinotariNewWalletCredentials credentials, {bool? isTestnet}) =>
      super.create(credentials, isTestnet: true);
  @override
  Future<WalletBase> restoreFromSeed(MinotariRestoreWalletFromSeedCredentials credentials,
          {bool? isTestnet}) =>
      super.restoreFromSeed(credentials, isTestnet: true);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment("MINOTARI_ESMERALDA_TESTS");

  testWidgets("XTM Esmeralda: create, restore, reopen and display native balance", (tester) async {
    // Never reset a normal profile: every run gets new files and in-memory stores.
    final Directory root;
    if (Platform.isLinux) {
      // Linux's normal root selection deliberately bypasses path_provider. Use
      // its existing env override, guarded before the app/database initializes.
      final path = Platform.environment["CAKE_WALLET_DIR"];
      expect(path, isNotNull, reason: "Linux needs a fresh /tmp/xtm-integration-* profile");
      root = Directory(path!);
      final temporary = await Directory.systemTemp.resolveSymbolicLinks();
      expect(await root.resolveSymbolicLinks(), root.path);
      expect(root.parent.path, temporary);
      expect(root.uri.pathSegments.where((part) => part.isNotEmpty).last,
          startsWith("xtm-integration-"));
      expect(await root.list().isEmpty, isTrue, reason: "The Linux test profile must be empty");
      expect(Platform.environment["XDG_DATA_HOME"], "${root.path}.xdg-data");
      expect(Platform.environment["XDG_CONFIG_HOME"], "${root.path}.xdg-config");
      setRootDirFromEnv();
    } else {
      expect(Platform.environment["CAKE_WALLET_DIR"], anyOf(isNull, isEmpty),
          reason: "CAKE_WALLET_DIR would override the isolated test profile");
      final temporary = await getTemporaryDirectory();
      await temporary.create(recursive: true);
      root = await Directory(temporary.path).createTemp("xtm-integration-");
    }
    PathProviderPlatform.instance = _IsolatedPaths(root.path);
    SharedPreferences.setMockInitialValues({PreferencesKey.currentLanguageCode: "en"});
    FlutterSecureStorage.setMockInitialValues({});
    expect((await getAppDir()).path, root.path);
    final flow = _MinotariFlows(tester);
    final originalFlutterError = FlutterError.onError;
    await flow.startAppFlow(const ValueKey("xtm_esmeralda_integration"));
    FlutterError.onError = originalFlutterError;
    expect(await WalletInfo.getAll(), isEmpty);

    // Restrict this entrypoint to XTM. Other currency suites/registrations are unchanged.
    await getIt.unregister<WalletService>();
    final service = _EsmeraldaService();
    getIt.registerFactoryParam<WalletService, WalletType, void>((type, _) {
      if (type != WalletType.minotari) {
        throw StateError("This integration entrypoint only supports XTM");
      }
      return service;
    });
    getIt.get<SettingsStore>().nodes[WalletType.minotari] =
        Node(uri: "127.0.0.1:1", type: WalletType.minotari, useSSL: false);

    MinotariWallet current() => getIt.get<AppStore>().wallet! as MinotariWallet;
    addTearDown(() async {
      await getIt.get<AppStore>().wallet?.close();
      // Keep this process on the isolated paths until it exits, including late callbacks.
    });
    Future<void> expectBalance(String text, int amount) async {
      await current().updateBalance();
      await tester.pumpAndSettle();
      expect(current().balance[CryptoCurrency.xtm]!.available.amount, BigInt.from(amount));
      final cards = tester.widgetList<BalanceCard>(find.byType(BalanceCard));
      expect(cards.any((card) => card.assetName.toUpperCase() == "XTM" && card.balance == text),
          isTrue,
          reason: "The real Home balance card must display the native XTM balance");
      expect(find.textContaining(text, findRichText: true), findsWidgets);
    }

    await flow.welcomePageToCreateNewWalletFlow(WalletType.minotari, CommonTestConstants.pin);
    expect(current().walletInfo.network, "esmeralda");
    expect(current().seed!.split(" "), hasLength(24));
    expect(current().address, startsWith("f"));
    await expectBalance("0", 0);
    final createdName = current().name;
    final createdAddress = current().address;
    final createdSeed = current().seed;
    final password = current().password;
    await current().close();
    final reopened = await service.openWallet(createdName, password) as MinotariWallet;
    expect(reopened.address, createdAddress);
    expect(reopened.seed, createdSeed);
    expect(reopened.walletInfo.network, "esmeralda");
    await getIt.get<AppStore>().changeCurrentWallet(reopened);

    // Same restore robot flow as other currencies; use the current app's wallet route.
    final context = tester.element(find.byType(BalanceCard).first);
    Navigator.of(context, rootNavigator: true).pushNamed(Routes.walletList);
    await tester.pumpAndSettle();
    final seed = flow.getWalletSeedsByWalletType(WalletType.minotari);
    expect(seed, MinotariTestWallet.seed);
    await flow.restoreWalletFromWalletMenu(WalletType.minotari, seed);
    expect(current().address, MinotariTestWallet.esmeraldaAddress);
    expect(current().walletInfo.network, "esmeralda");
    expect(current().seed, seed);
    await expectBalance("0", 0);

    // Deterministic ledger fixture, not a live-chain payment or a mock wallet.
    final path = "${await pathForWalletTypeDir(type: WalletType.minotari)}/wallet.db";
    expect(path, startsWith(root.path));
    // The platform SQLite driver and Rust's bundled SQLite must not access the
    // same file concurrently. Drain the scanner and close the native pool before
    // the fixture writer takes ownership, then reopen it for the actual assertion.
    await current().stopSync();
    await native_db.disconnectDatabase();
    final db = await openDatabase(path, singleInstance: false);
    try {
      final account = (await db.query("accounts",
              columns: ["id"], where: "friendly_name = ?", whereArgs: [current().name]))
          .single;
      await db.insert("balance_changes", {
        "account_id": account["id"],
        "description": "XTM integration fixture",
        "balance_credit": 2500001,
        "balance_debit": 0,
        "effective_date": "2026-01-01 00:00:00",
        "effective_height": 1,
        "is_reversal": 0,
        "is_reversed": 0,
      });
    } finally {
      await db.close();
      await native_db.initializeDatabase(path: path);
    }
    await expectBalance("2.500001", 2500001);
    binding.reportData = {
      "xtmCreate": true,
      "xtmRestore": true,
      "xtmReopen": true,
      "xtmZeroBalance": true,
      "xtmNonZeroBalance": true,
      "network": "esmeralda",
      "liveChain": false,
      "broadcast": false,
      "platform": Platform.operatingSystem,
      "abi": Abi.current().toString(),
    };
    await current().close();
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 8)));
}
