import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_minotari/minotari_runtime.dart';
import 'package:cw_minotari/src/rust/api/base_node.dart';
import 'package:cw_minotari/src/rust/api/scanner.dart';
import 'dart:async';
import 'dart:io';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_minotari/minotari_wallet.dart';
import 'package:cw_minotari/src/rust/api/balance.dart';
import 'package:cw_minotari/src/rust/api/network.dart';
import 'package:cw_minotari/src/rust/api/transactions.dart';
import 'package:cw_minotari/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Info extends Fake implements WalletInfo {
  @override
  bool get isRecovery => false;
  @override
  String get name => 'synthetic-fee-test';
  @override
  WalletType get type => WalletType.minotari;
  @override
  String? get network => 'mainNet';
  @override
  Future<Set<String>> getUsedAddresses() async => {};
  @override
  Future<Set<String>> getHiddenAddresses() async => {};
  @override
  Future<Set<String>> getManualAddresses() async => {};
}

class _Encryption extends Fake implements EncryptionFileUtils {}

class _RecoveryInfo extends _Info {
  @override
  bool isRecovery = true;
  int saves = 0;
  @override
  Future<int> save() async => ++saves;
}

DisplayedTransactionDto _receipt(String id, {bool confirmed = false}) => DisplayedTransactionDto(
    id: id,
    direction: DisplayedTransactionDirection.incoming,
    source: DisplayedTransactionSource.transfer,
    status:
        confirmed ? DisplayedTransactionStatus.confirmed : DisplayedTransactionStatus.unconfirmed,
    amount: BigInt.from(7000000),
    amountDisplay: '7.000000 XTM',
    blockchain: BlockchainInfoDto(
        blockHeight: BigInt.from(100),
        timestamp: '2026-10-24 07:31:56',
        confirmations: BigInt.from(confirmed ? 3 : 0)),
    payrefs: []);

class _Api extends Fake implements RustLibApi {
  int scans = 0;
  int stops = 0;
  int snapshots = 0;
  bool finishOnStop = true;
  Future<TipInfo?>? tip;
  Completer<void>? tipStarted;
  StreamController<ScanEventDto>? active;
  Future<void> Function()? beforeSnapshot;
  List<DisplayedTransactionDto> rows = [];
  @override
  Future<void> crateApiDbInitializeDatabase({required String path}) async {}
  @override
  Future<void> crateApiScannerStopScan() async {
    stops++;
    if (finishOnStop && active != null && !active!.isClosed) unawaited(active!.close());
  }

  @override
  Future<String> crateApiAddressGetAddress(
          {required String walletName, String? passphrase, TariNetwork? network}) async =>
      'synthetic-address';
  @override
  Future<AccountBalanceDto> crateApiBalanceGetBalance({required String walletName}) async =>
      AccountBalanceDto(
          total: BigInt.zero,
          available: BigInt.zero,
          locked: BigInt.zero,
          unconfirmed: BigInt.zero);
  @override
  Future<List<DisplayedTransactionDto>> crateApiTransactionsGetTransactions(
      {required String walletName, required int limit, required int offset}) async {
    snapshots++;
    await beforeSnapshot?.call();
    return rows;
  }

  @override
  Future<TipInfo?> crateApiBaseNodeGetTipInfo({required String baseUrl}) {
    tipStarted?.complete();
    return tip ?? Future.value(null);
  }

  @override
  Stream<ScanEventDto> crateApiScannerStartScan({required ScanConfiguration config}) {
    expect(config.continuous, isFalse);
    scans++;
    return (active = StreamController<ScanEventDto>(onCancel: () => Future<void>.value())).stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  late Directory root;
  late MinotariWallet wallet;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('xtm-background-wallet-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    RustLib.initMock(api: api);
  });
  tearDownAll(() async {
    RustLib.dispose();
    await root.delete(recursive: true);
  });
  setUp(() async {
    expect(await MinotariRuntime.instance.beginBackground(), isTrue);
    api.scans = api.stops = api.snapshots = 0;
    api.beforeSnapshot = null;
    api.rows = [];
    api.finishOnStop = true;
    api.tip = null;
    api.tipStarted = null;
    wallet = MinotariWallet(_Info(), DerivationInfo(),
        password: '',
        mnemonic: List.filled(24, 'synthetic').join(' '),
        encryptionFileUtils: _Encryption());
    await wallet.init();
    await wallet.connectToNode(node: Node(uri: 'rpc.invalid:443', type: WalletType.minotari));
  });
  tearDown(() async {
    await wallet.close();
    await MinotariRuntime.instance.endBackground();
  });
  Future<void> waitForScan() async {
    for (var i = 0; i < 100 && api.active == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(api.active, isNotNull);
  }

  Future<_RecoveryInfo> restorePreview() async {
    await wallet.close();
    api.active = null;
    final info = _RecoveryInfo();
    api.rows = [_receipt('old'), _receipt('fresh')];
    wallet =
        MinotariWallet(info, DerivationInfo(), password: '', encryptionFileUtils: _Encryption());
    await wallet.init();
    await wallet.connectToNode(node: Node(uri: 'rpc.invalid:443', type: WalletType.minotari));
    return info;
  }

  test('restore preview ends atomically and retains genuinely unconfirmed receipts', () async {
    final info = await restorePreview();
    final old = wallet.transactionHistory.transactions['old']!;
    expect(old.additionalInfo['restoringHistory'], isTrue);
    expect(old.isPending, isTrue); // Presentation never changes native pending state.
    final task = wallet.startBackgroundSync();
    await waitForScan();
    api.rows = [_receipt('old', confirmed: true), _receipt('fresh')];
    api.active!.add(ScanEventDto.status(ScanStatusDto.completed(
        accountId: 1, finalHeight: BigInt.from(103), totalBlocksScanned: BigInt.from(3))));
    await api.active!.close();
    await task;
    expect(info.isRecovery, isFalse);
    expect(info.saves, 1);
    expect(wallet.transactionHistory.transactions, hasLength(2));
    final finalOld = wallet.transactionHistory.transactions['old']!;
    final fresh = wallet.transactionHistory.transactions['fresh']!;
    expect(finalOld.additionalInfo['restoringHistory'], isFalse);
    expect(finalOld.isPending, isFalse);
    expect(fresh.additionalInfo['restoringHistory'], isFalse);
    expect(fresh.isPending, isTrue);
    expect(finalOld.date.toUtc(), DateTime.utc(2026, 10, 24, 7, 31, 56));
  });

  test('failed restore keeps preview and retries the final snapshot', () async {
    final info = await restorePreview();
    final failed = wallet.startBackgroundSync();
    final expectation = expectLater(failed, throwsStateError);
    await waitForScan();
    api.beforeSnapshot = () async => throw StateError('synthetic history read failure');
    api.active!.add(ScanEventDto.status(ScanStatusDto.completed(
        accountId: 1, finalHeight: BigInt.from(103), totalBlocksScanned: BigInt.from(3))));
    await api.active!.close();
    await expectation;
    expect(info.isRecovery, isTrue);
    expect(info.saves, 0);
    expect(
        wallet.transactionHistory.transactions['old']!.additionalInfo['restoringHistory'], isTrue);
    api.beforeSnapshot = null;
    api.active = null;
    final retry = wallet.startBackgroundSync();
    await waitForScan();
    api.active!.add(ScanEventDto.status(ScanStatusDto.completed(
        accountId: 1, finalHeight: BigInt.from(103), totalBlocksScanned: BigInt.zero)));
    await api.active!.close();
    await retry;
    expect(info.isRecovery, isFalse);
    expect(
        wallet.transactionHistory.transactions['old']!.additionalInfo['restoringHistory'], isFalse);
  });

  test('background waits for stream drain and final history before reporting synced', () async {
    api.active = null;
    final finishHistory = Completer<void>();
    final historyStarted = Completer<void>();
    api.beforeSnapshot = () {
      historyStarted.complete();
      return finishHistory.future;
    };
    var completed = false;
    final task = wallet.startBackgroundSync().then((_) => completed = true);
    await waitForScan();
    api.active!.add(ScanEventDto.status(ScanStatusDto.completed(
        accountId: 1, finalHeight: BigInt.one, totalBlocksScanned: BigInt.one)));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    final closed = api.active!.close();
    await historyStarted.future;
    expect(completed, isFalse);
    expect(wallet.syncStatus, isNot(isA<SyncedSyncStatus>()));
    finishHistory.complete();
    await task;
    await closed;
    expect(wallet.syncStatus, isA<SyncedSyncStatus>());
    expect(api.scans, 1);
    expect(api.snapshots, 2);
    expect(api.stops, greaterThanOrEqualTo(2));
  });
  test('native failure cleans up and later job can retry', () async {
    api.active = null;
    final failed = wallet.startBackgroundSync();
    final failure = expectLater(failed, throwsStateError);
    await waitForScan();
    api.active!.add(const ScanEventDto.error('synthetic offline'));
    await failure;
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
    api.active = null;
    final retry = wallet.startBackgroundSync();
    await waitForScan();
    api.active!.add(ScanEventDto.status(ScanStatusDto.completed(
        accountId: 1, finalHeight: BigInt.one, totalBlocksScanned: BigInt.zero)));
    await api.active!.close();
    await retry;
    expect(wallet.syncStatus, isA<SyncedSyncStatus>());
    expect(api.scans, 2);
  });
  test('stream ending without native Completed is a failed pass', () async {
    api.active = null;
    final task = wallet.startBackgroundSync();
    final failure = expectLater(task, throwsStateError);
    await waitForScan();
    await api.active!.close();
    await failure;
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
  });
  test('stop waits for native exit before releasing ownership', () async {
    api.active = null;
    api.finishOnStop = false;
    final task = wallet.startBackgroundSync();
    final failure = expectLater(task, throwsStateError);
    await waitForScan();
    var stopped = false;
    final stopping = wallet.stopSync().then((_) => stopped = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(stopped, isFalse);
    expect(MinotariRuntime.instance.ownsNative, isTrue);
    await api.active!.close();
    await stopping;
    await failure;
  });
  test('stop does not wait for a stateless tip RPC or accept its late response', () async {
    api.active = null;
    final tip = Completer<TipInfo?>();
    api.tip = tip.future;
    api.tipStarted = Completer<void>();
    final task = wallet.startBackgroundSync();
    final failure = expectLater(task, throwsStateError);
    await api.tipStarted!.future;
    await wallet.stopSync();
    await failure;
    expect(api.scans, 0);
    tip.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(api.scans, 0);
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
  });
  test('deadline stops a native stream that never finishes', () async {
    api.active = null;
    final task = wallet.startBackgroundSync();
    final failure = expectLater(task, throwsA(isA<TimeoutException>()));
    await waitForScan();
    await failure;
    expect(api.stops, greaterThanOrEqualTo(2));
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
  }, timeout: const Timeout(Duration(minutes: 4)));
  test('foreground request cancels native pass and permits cleanup', () async {
    api.active = null;
    final task = wallet.startBackgroundSync();
    final failure = expectLater(task, throwsStateError);
    await waitForScan();
    final path = await pathForWalletTypeDir(type: WalletType.minotari);
    final request = File('$path/foreground.request');
    await request.writeAsString(DateTime.now().toIso8601String());
    try {
      await failure;
    } finally {
      await request.delete();
    }
    expect(api.stops, greaterThanOrEqualTo(2));
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
  });
}
