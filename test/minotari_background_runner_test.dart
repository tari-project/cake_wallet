import 'dart:async';

import 'package:cake_wallet/core/background_sync.dart';
import 'package:cake_wallet/core/key_service.dart';
import 'package:cake_wallet/core/wallet_loading_service.dart';
import 'package:cake_wallet/di.dart';
import 'package:cake_wallet/minotari/minotari.dart' as xtm;
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
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
  @override
  String get name => 'disposable';
  @override
  String get id => 'disposable-id';
  @override
  SyncStatus syncStatus = NotConnectedSyncStatus();
  @override
  final transactionHistory = _History();
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
  Future<void> stopBackgroundSync(String password) async => calls.add('stop');
  @override
  Future<void> close({bool shouldCleanup = false}) async {
    expect(shouldCleanup, isTrue);
    calls.add('close');
  }
}

class _Minotari extends Fake implements xtm.Minotari {
  _Minotari(this.calls);
  final List<String> calls;
  bool available = true;
  @override
  Future<bool> beginBackgroundSync() async {
    calls.add('acquire');
    return available;
  }

  @override
  Future<void> endBackgroundSync() async => calls.add('release');
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
  final original = xtm.minotari;
  final calls = <String>[];
  late _Wallet wallet;
  late _Loading loading;
  late _Minotari adapter;
  late Future<List<WalletInfo>> Function() loadWallets;
  BackgroundSync runner({bool Function()? isCancelled}) =>
      BackgroundSync(isCancelled: isCancelled, loadWallets: () => loadWallets());
  Future<void> configure([WalletType type = WalletType.minotari]) async {
    await getIt.reset();
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    wallet = _Wallet(type, calls);
    loading = _Loading(wallet);
    adapter = _Minotari(calls);
    xtm.minotari = adapter;
    getIt.registerSingleton<WalletLoadingService>(loading);
    loadWallets = () async => [_Info(type)];
    getIt.registerSingleton<SettingsStore>(_Settings());
    getIt.registerSingleton<KeyService>(_Keys());
  }

  setUp(configure);
  tearDown(() async {
    xtm.minotari = original;
    await getIt.reset();
  });

  test('XTM acquires before loading; completes one pass and closes before releasing', () async {
    await runner().sync();
    expect(calls, ['acquire', 'load', 'connect', 'start', 'close', 'release']);
  });
  test('headless runner waits for its stable persisted wallet snapshot', () async {
    final loaded = Completer<List<WalletInfo>>();
    loadWallets = () => loaded.future;
    final job = runner().sync();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    loaded.complete([_Info(WalletType.minotari)]);
    await job;
    expect(calls, ['acquire', 'load', 'connect', 'start', 'close', 'release']);
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
  test('busy XTM runtime skips loading without releasing someone else\'s lease', () async {
    adapter.available = false;
    await runner().sync();
    expect(calls, ['acquire']);
  });
  test('load failure releases XTM ownership so later job may retry', () async {
    loading.fail = true;
    await runner().sync();
    expect(calls, ['acquire', 'load', 'release']);
    calls.clear();
    loading.fail = false;
    await runner().sync();
    expect(calls.last, 'release');
    expect(calls, contains('start'));
  });
  test('failed XTM scan still closes and releases', () async {
    wallet.scan = () async => throw StateError('offline');
    await runner().sync();
    expect(calls, ['acquire', 'load', 'connect', 'start', 'close', 'release']);
  });
  test('cancelling an active XTM pass closes it before releasing', () async {
    var cancelled = false;
    final started = Completer<void>();
    final finish = Completer<void>();
    wallet.scan = () {
      started.complete();
      return finish.future;
    };
    final task = runner(isCancelled: () => cancelled).sync();
    await started.future;
    cancelled = true;
    await task;
    expect(calls.sublist(calls.length - 2), ['close', 'release']);
    finish.complete();
  });
  test('already cancelled runner never opens a wallet', () async {
    await runner(isCancelled: () => true).sync();
    expect(calls, isEmpty);
  });
  test('other currency preserves connect/start/stable-sync/stop/close path', () async {
    await configure(WalletType.solana);
    await runner().sync();
    expect(calls, ['load', 'connect', 'start', 'stop', 'stop', 'close']);
  });
  test('other currency cancellation stops and closes without XTM ownership calls', () async {
    await configure(WalletType.solana);
    await runner(isCancelled: () => calls.contains('load')).sync();
    expect(calls, ['load', 'stop', 'close']);
  });
}
