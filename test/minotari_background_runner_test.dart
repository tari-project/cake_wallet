import 'dart:async';

import 'package:cake_wallet/core/background_sync.dart';
import 'package:cake_wallet/core/key_service.dart';
import 'package:cake_wallet/core/wallet_loading_service.dart';
import 'package:cake_wallet/di.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_core/wallet_service.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _History extends Fake implements TransactionHistoryBase {
  @override
  final transactions = ObservableMap<String, TransactionInfo>();
}

class _Wallet extends Fake implements WalletBase {
  _Wallet(this.type, this.calls);
  @override
  final WalletType type;
  final List<String> calls;
  Future<void> Function()? scan;
  bool stopFails = false;
  bool historyFails = false;
  @override
  String get name => 'disposable';
  @override
  String get id => 'disposable-id';
  @override
  SyncStatus syncStatus = NotConnectedSyncStatus();
  @override
  TransactionHistoryBase get transactionHistory {
    if (historyFails) throw StateError('history failed');
    return _history;
  }

  final _history = _History();
  @override
  Future<void> connectToNode({required Node node}) async {
    calls.add('connect');
    syncStatus = ConnectedSyncStatus();
  }

  @override
  Future<void> startBackgroundSync() async {
    calls.add('start');
    if (scan != null) return scan!();
    syncStatus = SyncedSyncStatus();
  }

  @override
  Future<void> stopBackgroundSync(String password) async {
    calls.add('stop');
    if (stopFails) throw StateError('stop failed');
  }

  @override
  Future<void> close({bool shouldCleanup = false}) async {
    expect(shouldCleanup, isTrue);
    calls.add('close');
  }
}

class _Loading extends Fake implements WalletLoadingService {
  _Loading(this.wallet);
  final _Wallet wallet;
  bool fail = false;
  @override
  Future<WalletBase> load(WalletType type, String name,
      {String? password, bool isBackground = false}) async {
    expect(isBackground, isTrue);
    wallet.calls.add('load');
    if (fail) throw StateError('load failed');
    return wallet;
  }
}

class _Info extends Fake implements WalletInfo {
  _Info(this.type, {this.isHardwareWallet = false});
  @override
  final WalletType type;
  @override
  final bool isHardwareWallet;
  @override
  String get name => 'disposable';
}

class _UnavailableService extends Fake implements WalletService {
  @override
  Future<WalletBase> openWallet(String name, String password) async {
    throw StateError('wallet unavailable');
  }
}

class _Settings extends Fake implements SettingsStore {
  @override
  bool get currentBuiltinTor => false;
  @override
  Node getCurrentNode(WalletType type, {int? chainId}) => Node(uri: 'rpc.invalid:443', type: type);
}

class _Keys extends Fake implements KeyService {
  @override
  Future<String> getWalletPassword({required String walletName}) async => 'synthetic';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  late _Wallet wallet;
  late _Loading loading;
  late Future<List<WalletInfo>> Function() loadWallets;
  BackgroundSync runner({bool Function()? isCancelled}) =>
      BackgroundSync(isCancelled: isCancelled, loadWallets: () => loadWallets());
  Future<void> configure([WalletType type = WalletType.minotari]) async {
    await getIt.reset();
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    wallet = _Wallet(type, calls);
    loading = _Loading(wallet);
    getIt.registerSingleton<WalletLoadingService>(loading);
    loadWallets = () async => [_Info(type)];
    getIt.registerSingleton<SettingsStore>(_Settings());
    getIt.registerSingleton<KeyService>(_Keys());
  }

  setUp(configure);
  tearDown(() async {
    await getIt.reset();
  });

  test('upstream paused budget closes its own session without reconnecting', () async {
    wallet.syncStatus = PausedSyncStatus();
    await runner().sync();
    expect(calls, ['load', 'stop', 'close']);
  });
  test('foreground-owned scan is left to native session handover', () async {
    wallet.syncStatus = HandledByForegroundSyncStatus();
    await runner().sync();
    expect(calls, ['load', 'stop', 'close']);
  });
  test('headless runner waits for its persisted wallet snapshot', () async {
    final loaded = Completer<List<WalletInfo>>();
    loadWallets = () => loaded.future;
    wallet.syncStatus = PausedSyncStatus();
    final job = runner().sync();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    loaded.complete([_Info(WalletType.minotari)]);
    await job;
    expect(calls, ['load', 'stop', 'close']);
  });
  test('hardware, Haven and Decred exclusions are preserved', () async {
    loadWallets = () async => [
          _Info(WalletType.minotari, isHardwareWallet: true),
          _Info(WalletType.haven),
          _Info(WalletType.decred),
        ];
    await runner().sync();
    expect(calls, isEmpty);
  });
  test('already cancelled runner never opens a wallet', () async {
    await runner(isCancelled: () => true).sync();
    expect(calls, isEmpty);
  });
  test('cancellation after loading stops and closes before opening another wallet', () async {
    loadWallets = () async => [_Info(WalletType.minotari), _Info(WalletType.minotari)];
    await runner(isCancelled: () => calls.contains('load')).sync();
    expect(calls, ['load', 'stop', 'close']);
  });
  test('failed reconnect still stops and closes the loaded session', () async {
    wallet.scan = () async => throw StateError('offline');
    await expectLater(runner().sync(), throwsStateError);
    expect(calls, ['load', 'connect', 'start', 'stop', 'close']);
  });
  test('history failure cannot leak the native session', () async {
    wallet.syncStatus = PausedSyncStatus();
    wallet.historyFails = true;
    await expectLater(runner().sync(), throwsStateError);
    expect(calls, ['load', 'stop', 'close']);
  });
  test('stop failure still closes the wallet', () async {
    wallet.syncStatus = PausedSyncStatus();
    wallet.stopFails = true;
    await expectLater(runner().sync(), throwsStateError);
    expect(calls, ['load', 'stop', 'close']);
  });
  test('other currency preserves connect/start/stable-sync/stop/close', () async {
    await configure(WalletType.solana);
    await runner().sync();
    expect(calls, ['load', 'connect', 'start', 'stop', 'close']);
  });
  test('other currency cancellation closes its loaded wallet', () async {
    await configure(WalletType.solana);
    await runner(isCancelled: () => calls.contains('load')).sync();
    expect(calls, ['load', 'stop', 'close']);
  });
  test('background open failure preserves selection and does not enter seed recovery', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PreferencesKey.currentWalletName, 'user-selected-wallet');
    var opens = 0;
    final realLoading = WalletLoadingService(prefs, _Keys(), (_) {
      opens++;
      return _UnavailableService();
    });
    await expectLater(
      realLoading.load(WalletType.minotari, 'unavailable', isBackground: true),
      throwsA(isA<StateError>().having((e) => e.message, 'original error', 'wallet unavailable')),
    );
    expect(opens, 1);
    expect(prefs.getString(PreferencesKey.currentWalletName), 'user-selected-wallet');
  });
}
