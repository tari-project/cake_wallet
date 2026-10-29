import 'dart:async';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_keys_file.dart';
import 'package:cw_tari_ootle/pending_tari_ootle_transaction.dart';
import 'package:cw_tari_ootle/src/rust/api/send.dart' as bridge;
import 'package:cw_tari_ootle/src/rust/api/sync.dart' as bridge;
import 'package:cw_tari_ootle/src/rust/api/wallet.dart' as bridge;
import 'package:cw_tari_ootle/tari_ootle_balance.dart';
import 'package:cw_tari_ootle/tari_ootle_ffi.dart';
import 'package:cw_tari_ootle/tari_ootle_transaction_history.dart';
import 'package:cw_tari_ootle/tari_ootle_transaction_info.dart';
import 'package:cw_tari_ootle/tari_ootle_wallet_addresses.dart';
import 'package:mobx/mobx.dart';

part 'tari_ootle_wallet.g.dart';

/// How often an open wallet re-scans the indexer for new activity.
const tariOotleRescanInterval = Duration(seconds: 30);

/// The bridge refuses fees above 0.1 TARI (µT), the same ceiling Universe applies.
final _maxFee = BigInt.from(100000);

class TariOotleWallet = TariOotleWalletBase with _$TariOotleWallet;

abstract class TariOotleWalletBase
    extends WalletBase<TariOotleBalance, TariOotleTransactionHistory, TariOotleTransactionInfo>
    with Store, WalletKeysFile {
  TariOotleWalletBase(
    WalletInfo walletInfo,
    DerivationInfo derivationInfo, {
    required String mnemonic,
    required String password,
    required this.network,
    required this.encryptionFileUtils,
    bool isNewWallet = false,
  })  : _mnemonic = mnemonic,
        _password = password,
        _isNewWallet = isNewWallet,
        balance = ObservableMap.of({CryptoCurrency.tari: TariOotleBalance.zero()}),
        syncStatus = NotConnectedSyncStatus(),
        walletAddresses = TariOotleWalletAddresses(
            walletInfo, network == TariOotleNetwork.esmeralda),
        super(walletInfo, derivationInfo) {
    isTestnet = network == TariOotleNetwork.esmeralda;
    transactionHistory = TariOotleTransactionHistory();
  }

  final TariOotleNetwork network;
  final EncryptionFileUtils encryptionFileUtils;
  final String _mnemonic;
  String _password;

  /// Created in this session: on first open the bridge starts scanning at the current epoch.
  final bool _isNewWallet;

  bool _isOpen = false;
  Node? _node;
  StreamSubscription<bridge.ScanEvent>? _scan;
  Timer? _rescanTimer;

  /// Fee of the last [createTransaction], shown as the estimate until the next one.
  BigInt? _lastFee;

  @override
  TariOotleWalletAddresses walletAddresses;

  @override
  @observable
  SyncStatus syncStatus;

  @override
  @observable
  ObservableMap<CryptoCurrency, TariOotleBalance> balance;

  @override
  String get seed => _mnemonic;

  @override
  String get password => _password;

  @override
  WalletKeysData get walletKeysData => WalletKeysData(mnemonic: _mnemonic);

  @override
  Object get keys => {};

  @override
  bool get canSignMessages => false;

  Money? get estimatedFee => _lastFee == null ? null : Money(_lastFee!, CryptoCurrency.tari);

  Future<void> init() async {
    await initTariOotleLib();
    walletAddresses.address = await bridge.addressFromSeed(seedWords: _mnemonic, network: network);
  }

  /// The bridge needs an indexer URL to open, so the wallet opens on the first connect.
  @override
  Future<void> connectToNode({required Node node}) async {
    _node = node;
    final url = node.uri.toString();
    try {
      syncStatus = ConnectingSyncStatus();
      if (_isOpen) {
        await bridge.setIndexerUrl(name: walletInfo.name, indexerUrl: url);
      } else {
        await _open(url);
      }
      syncStatus = ConnectedSyncStatus();
    } catch (e) {
      printV('[TariOotle] connect failed: $e');
      syncStatus = FailedSyncStatus(error: e.toString());
    }
  }

  Future<void> _open(String indexerUrl) async {
    var birthday = walletInfo.restoreHeight;
    if (_isNewWallet && birthday == 0) {
      try {
        birthday = (await bridge.getCurrentEpoch(indexerUrl: indexerUrl)).toInt();
        walletInfo.restoreHeight = birthday;
        await walletInfo.save();
      } catch (e) {
        printV('[TariOotle] could not fetch current epoch, scanning from 0: $e');
      }
    }
    final info = await bridge.openWallet(
      req: bridge.OpenWalletRequest(
        name: walletInfo.name,
        dataDir: await pathForWalletDir(name: walletInfo.name, type: type),
        seedWords: _mnemonic,
        network: network,
        indexerUrl: indexerUrl,
        birthdayEpoch: BigInt.from(birthday),
      ),
    );
    walletAddresses.address = info.address;
    _isOpen = true;
    await updateBalance();
    await updateTransactions();
  }

  @override
  Future<void> startSync() async {
    if (!_isOpen) {
      syncStatus = FailedSyncStatus(error: 'No indexer connected');
      return;
    }
    _rescanTimer ??= Timer.periodic(tariOotleRescanInterval, (_) {
      if (_scan == null) startSync();
    });
    await _scan?.cancel();
    syncStatus = AttemptingSyncStatus();
    // A new scan replaces a running one inside the bridge too.
    _scan = bridge.startScan(name: walletInfo.name).listen(
      (event) async {
        switch (event) {
          case bridge.ScanEvent_Progress():
            syncStatus = SyncronizingSyncStatus();
            await updateBalance();
            await updateTransactions();
          case bridge.ScanEvent_Completed():
            await updateBalance();
            await updateTransactions();
            syncStatus = SyncedSyncStatus();
          case bridge.ScanEvent_Failed(:final message):
            printV('[TariOotle] scan failed: $message');
            syncStatus = FailedSyncStatus(error: message);
        }
      },
      onError: (Object e) {
        printV('[TariOotle] scan stream error: $e');
        syncStatus = FailedSyncStatus(error: e.toString());
      },
      onDone: () => _scan = null,
    );
  }

  @override
  Future<void> stopSync() async {
    _rescanTimer?.cancel();
    _rescanTimer = null;
    await _scan?.cancel();
    _scan = null;
    if (_isOpen) await bridge.stopScan(name: walletInfo.name);
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    if (!_isOpen) throw Exception('Tari wallet is not connected to an indexer');
    final output = (credentials as TariOotleTransactionCredentials).outputs.first;
    final to = output.isParsedAddress ? (output.extractedAddress ?? output.address) : output.address;
    if (!bridge.validateAddress(address: to, network: network)) {
      throw Exception('Invalid Tari address for ${network.name}');
    }

    final BigInt amount;
    final BigInt fee;
    if (output.sendAll) {
      // The bridge selects inputs for amount + fee, so it cannot price a send of the whole balance.
      // Price one that leaves room for the largest fee it accepts, then send the rest at that fee.
      // TODO: a full-balance send that needs a higher fee than the probe fails at the network.
      final available = balance[CryptoCurrency.tari]!.available.amount;
      final probe = available > _maxFee ? available - _maxFee : available ~/ BigInt.two;
      if (probe <= BigInt.zero) throw Exception('Balance too low to send');
      fee = await bridge.estimateFee(name: walletInfo.name, to: to, amount: probe);
      amount = available - fee;
    } else {
      amount = output.cryptoAmount.amount;
      fee = await bridge.estimateFee(name: walletInfo.name, to: to, amount: amount);
    }
    if (amount <= BigInt.zero) throw Exception('Amount must be above the fee');
    _lastFee = fee;

    final memo = output.memo;
    return PendingTariOotleTransaction(
      amount: Money(amount, CryptoCurrency.tari),
      fee: Money(fee, CryptoCurrency.tari),
      recipientAddress: to,
      send: () => _send(to, amount, fee, memo == null || memo.isEmpty ? null : memo),
    );
  }

  Future<String> _send(String to, BigInt amount, BigInt fee, String? memo) async {
    final events = bridge.sendTransaction(
        name: walletInfo.name, to: to, amount: amount, fee: fee, memo: memo);
    String? txId;
    await for (final event in events) {
      switch (event) {
        case bridge.SendEvent_Submitted(txId: final id):
          printV('[TariOotle] submitted $id');
        case bridge.SendEvent_Completed(txId: final id):
          txId = id;
        case bridge.SendEvent_Failed(:final message):
          throw Exception(message);
      }
    }
    if (txId == null) throw Exception('Send ended without a result');
    await updateBalance();
    await updateTransactions();
    unawaited(startSync());
    return txId;
  }

  @override
  int calculateEstimatedFee(TransactionPriority priority, int? amount) => _lastFee?.toInt() ?? 0;

  @override
  Future<Map<String, TariOotleTransactionInfo>> fetchTransactions() async {
    if (!_isOpen) return {};
    final txs = await bridge.getTransactions(name: walletInfo.name);
    return {for (final tx in txs) tx.id: _toInfo(tx)};
  }

  TariOotleTransactionInfo _toInfo(bridge.TransactionDto tx) {
    final info = TariOotleTransactionInfo(
      id: tx.id,
      amount: Money(tx.amount, CryptoCurrency.tari),
      fee: Money(tx.fee, CryptoCurrency.tari),
      direction: tx.direction == bridge.TxDirection.incoming
          ? TransactionDirection.incoming
          : TransactionDirection.outgoing,
      isPending: tx.status == bridge.TxStatus.pending,
      date: DateTime.fromMillisecondsSinceEpoch(tx.timestampMs.toInt()),
      counterparty: tx.counterparty,
    );
    info.additionalInfo['status'] = tx.status.name;
    if (tx.memo != null) info.additionalInfo['message'] = tx.memo!;
    if (tx.error != null) info.additionalInfo['error'] = tx.error!;
    return info;
  }

  @override
  Future<void> updateBalance() async {
    if (!_isOpen) return;
    try {
      final b = await bridge.getBalance(name: walletInfo.name);
      balance[CryptoCurrency.tari] =
          TariOotleBalance.fromMicro(available: b.available, pendingOutgoing: b.pendingOutgoing);
    } catch (e) {
      printV('[TariOotle] balance update failed: $e');
    }
  }

  Future<void> updateTransactions() async {
    try {
      transactionHistory.addMany(await fetchTransactions());
    } catch (e) {
      printV('[TariOotle] history update failed: $e');
    }
  }

  @override
  Future<void> save() async {
    if (!(await WalletKeysFile.hasKeysFile(walletInfo.name, walletInfo.type))) {
      await saveKeysFile(_password, encryptionFileUtils);
      await saveKeysFile(_password, encryptionFileUtils, true);
    }
  }

  @override
  Future<void> changePassword(String password) async {
    _password = password;
    await saveKeysFile(password, encryptionFileUtils);
    await saveKeysFile(password, encryptionFileUtils, true);
  }

  /// The bridge has no rescan-from-height; a fresh scan resumes from its saved cursor.
  @override
  Future<void> rescan({required int height}) => startSync();

  @override
  Future<void> close({bool shouldCleanup = false}) async {
    await stopSync();
    if (_isOpen) await bridge.closeWallet(name: walletInfo.name);
    _isOpen = false;
  }

  @override
  Future<bool> checkNodeHealth() async => await _node?.requestNode() ?? false;

  @override
  Future<String> signMessage(String message, {String? address}) =>
      throw UnimplementedError('Tari Ootle message signing is not supported');

  @override
  Future<bool> verifyMessage(String message, String signature, {String? address}) async => false;
}
