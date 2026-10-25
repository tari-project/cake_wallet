import 'dart:async';
import 'dart:io';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_keys_file.dart';
import 'package:cw_minotari/minotari_balance.dart';
import 'package:cw_minotari/minotari_balance_updater.dart';
import 'package:cw_minotari/minotari_ffi.dart';
import 'package:cw_minotari/minotari_sync_loop.dart';
import 'package:cw_minotari/minotari_runtime.dart';
import 'package:cw_minotari/minotari_transaction_status.dart';
import 'package:cw_minotari/minotari_transaction_date.dart';
import 'package:cw_minotari/minotari_transaction_history.dart';
import 'package:cw_minotari/minotari_transaction_info.dart';
import 'package:cw_minotari/minotari_transaction_priority.dart';
import 'package:cw_minotari/minotari_wallet_addresses.dart';
import 'package:cw_minotari/pending_minotari_transaction.dart';
import 'package:cw_minotari/src/rust/api/base_node.dart' as base_node;
import 'package:cw_minotari/src/rust/api/network.dart';
import 'package:cw_minotari/src/rust/api/scanner.dart';
import 'package:cw_minotari/src/rust/api/transactions.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:mobx/mobx.dart';

part 'minotari_wallet.g.dart';

class MinotariWallet = MinotariWalletBase with _$MinotariWallet;

abstract class MinotariWalletBase
    extends WalletBase<MinotariBalance, MinotariTransactionHistory, MinotariTransactionInfo>
    with Store, WalletKeysFile {
  MinotariWalletBase(
    WalletInfo walletInfo,
    DerivationInfo derivationInfo, {
    String? mnemonic,
    required String password,
    required this.encryptionFileUtils,
    this.passphrase,
    this.viewPrivateKeyHex,
    this.spendPublicKeyHex,
  })  : _mnemonic = mnemonic,
        _password = password,
        balance = ObservableMap.of({
          CryptoCurrency.xtm: MinotariBalance(
            available: 0,
            pendingIncoming: 0,
            pendingOutgoing: 0,
          )
        }),
        _isTransactionUpdating = false,
        walletAddresses = MinotariWalletAddresses(walletInfo),
        syncStatus = NotConnectedSyncStatus(),
        super(walletInfo, derivationInfo) {
    transactionHistory = MinotariTransactionHistory();
  }

  MinotariFfi? _ffi;
  bool _isTransactionUpdating;
  bool _historyNeedsReload = true;
  bool _restoringHistory = false;
  int _historyGeneration = 0;
  final _historyUpdates = MinotariHistoryUpdateQueue();
  late final _balanceUpdates = MinotariBalanceUpdater(
    readBalance: _readBalance,
    currentBalance: () => balance[CryptoCurrency.xtm],
    publishBalance: (next) => balance[CryptoCurrency.xtm] = next,
  );
  late final _syncLoop = MinotariSyncLoop<ScanEventDto>(
    scan: _openScan,
    onEvent: _handleScanEvent,
    refresh: _refreshAfterScan,
    onSynced: () => syncStatus = SyncedSyncStatus(),
    onError: (error, stack) {
      _historyNeedsReload = true;
      printV('Minotari sync cycle failed: $error');
      syncStatus = FailedSyncStatus();
    },
  );
  Node? _currentNode;
  int _chainTipHeight = 0;
  int _initialSyncHeight = 0;

  /// Only a completed quote for the latest amount/priority/payment is cached.
  FeeEstimate? _cachedFeeEstimate;
  BigInt? _cachedFeeAmount;
  FeePriority? _cachedFeePriority;
  int _feeRequest = 0;
  ({BigInt amount, FeePriority priority, String? paymentId, String url})? _activeFeeKey;

  void _invalidateFee() {
    _feeRequest++;
    _cachedFeeEstimate = null;
    _cachedFeeAmount = null;
    _cachedFeePriority = null;
    _activeFeeKey = null;
  }

  final String _password;
  final String? _mnemonic;
  final EncryptionFileUtils encryptionFileUtils;

  @override
  MinotariWalletAddresses walletAddresses;

  @override
  @observable
  SyncStatus syncStatus;

  @override
  @observable
  ObservableMap<CryptoCurrency, MinotariBalance> balance;

  @override
  String? get seed => _mnemonic;

  /// password - for encrypting/decrypting the .keys file
  @override
  String get password => _password;

  /// BIP39 passphrase used for seed derivation
  @override
  final String? passphrase;

  final String? viewPrivateKeyHex;
  final String? spendPublicKeyHex;

  @override
  WalletKeysData get walletKeysData => WalletKeysData(
        mnemonic: _mnemonic,
        passphrase: passphrase,
        scanSecret: viewPrivateKeyHex,
        spendPubkey: spendPublicKeyHex,
      );

  @override
  Object get keys => {};

  String get address => walletAddresses.address;

  Future<void> init() async {
    try {
      await MinotariRuntime.instance.attach(this, pause: _stopSync, resume: _resumeSync);
      final dbPath = '${await pathForWalletTypeDir(type: walletInfo.type)}/wallet.db';
      _ffi = MinotariFfi(dataPath: dbPath, walletName: walletInfo.name);

      // Get the network from wallet info (defaults to mainnet if not set)
      final network = TariNetwork.values.firstWhere(
        (n) => n.name == walletInfo.network,
        orElse: () => TariNetwork.mainNet,
      );

      // Open the existing wallet database with the correct network
      await _ffi?.open(network);
      _restoringHistory = walletInfo.isRecovery;

      // Get the wallet address from the Rust layer (it's persisted there)
      final address = await _ffi?.getAddress(passphrase: passphrase ?? '');
      if (address != null && address.isNotEmpty) {
        walletAddresses.setAddress(address);
      } else {
        printV('Warning: Could not retrieve wallet address from FFI');
      }

      await updateBalance();
      await updateTransactions();
    } catch (e) {
      MinotariRuntime.instance.detach(this);
      printV('Error initializing Minotari wallet: $e');
      rethrow;
    }
  }

  Future<void> _resumeSync() async {
    if (_ffi == null) return;
    await _ffi!.resume();
    _historyNeedsReload = true;
    await updateTransactions();
    await updateBalance();
    if (_currentNode != null) await startSync();
  }

  @override
  Future<void> connectToNode({required Node node}) async {
    _invalidateFee();
    try {
      await _stopSync();
      syncStatus = ConnectingSyncStatus();

      // Store the node for later use
      _currentNode = node;

      // Test connection by fetching balance
      await updateBalance();

      syncStatus = ConnectedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
      rethrow;
    }
  }

  @override
  Future<void> startSync() async {
    if (_currentNode == null || _ffi == null) {
      syncStatus = FailedSyncStatus();
      return;
    }
    _balanceUpdates.invalidate();
    // Restarting cancels any prior stream, whose final IDs may not be delivered.
    _historyNeedsReload = true;
    await _syncLoop.start();
  }

  @override
  Future<void> startBackgroundSync() async {
    if (_currentNode == null || _ffi == null) {
      syncStatus = FailedSyncStatus();
      throw StateError('Minotari background sync needs an open wallet and node');
    }
    _balanceUpdates.invalidate();
    _historyNeedsReload = true;
    final cancelled = Completer<void>();
    final cancellation = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (MinotariRuntime.instance.backgroundCancelled && !cancelled.isCompleted) {
        cancelled.completeError(StateError('Minotari foreground requested'));
      }
    });
    try {
      await Future.any([_syncLoop.runOnce(), cancelled.future]).timeout(const Duration(minutes: 3));
      if (syncStatus is! SyncedSyncStatus || !_scanCompleted) {
        throw StateError('Minotari background scan did not complete');
      }
    } catch (_) {
      syncStatus = FailedSyncStatus();
      rethrow;
    } finally {
      cancellation.cancel();
      await _stopSync();
    }
  }

  @override
  Future<void> stopSync() => _stopSync();

  bool _scanCompleted = false;
  Completer<void>? _openingCancelled;

  Future<Stream<ScanEventDto>> _openScan(bool Function() isCurrent) async {
    _scanCompleted = false;
    final cancelled = Completer<void>();
    _openingCancelled = cancelled;
    try {
      await MinotariRuntime.instance.ensureSession();
      if (!isCurrent()) return const Stream<ScanEventDto>.empty();
      await _ffi!.resume();
      if (!isCurrent()) return const Stream<ScanEventDto>.empty();
      syncStatus = AttemptingSyncStatus();
      final nodeUrl = _currentNode!.uri.toString();
      try {
        // Tip RPC is stateless: cancelling its wait must not delay native handover.
        // Future.any observes late failures too; isCurrent rejects late responses.
        final tipInfo = await Future.any([
          base_node.getTipInfo(baseUrl: nodeUrl),
          cancelled.future.then<base_node.TipInfo?>((_) => null),
        ]);
        if (!isCurrent()) return const Stream<ScanEventDto>.empty();
        if (tipInfo != null) _chainTipHeight = tipInfo.bestBlockHeight.toInt();
      } catch (e) {
        if (!isCurrent()) return const Stream<ScanEventDto>.empty();
        printV('Error fetching chain tip: $e');
      }
      if (!isCurrent()) return const Stream<ScanEventDto>.empty();
      _balanceUpdates.beginScan();
      final stream = _ffi!.startScan(
        baseNodeAddress: nodeUrl,
        passphrase: passphrase ?? '',
        continuous: false,
      );
      syncStatus = SyncronizingSyncStatus();
      return stream;
    } finally {
      if (identical(_openingCancelled, cancelled)) _openingCancelled = null;
    }
  }

  Future<void> _refreshAfterScan(bool Function() isCurrent) async {
    // PR #149 runs the upstream monitor before the scan completes. Consume its
    // changes; do not recalculate confirmations independently in Cake Wallet.
    try {
      if (_restoringHistory && _scanCompleted) {
        await _runHistoryUpdate(isCurrent, () async {
          // The post-scan monitor has supplied final statuses. Replace preview
          // rows as one snapshot, including those with no native status change.
          _restoringHistory = false;
          try {
            await _loadTransactions(isCurrent: isCurrent);
            if (!isCurrent()) {
              _restoringHistory = true;
              return;
            }
            walletInfo.isRecovery = false;
            await walletInfo.save();
          } catch (_) {
            _restoringHistory = true;
            walletInfo.isRecovery = true;
            rethrow;
          }
        });
      } else {
        await _updateHistoryChanges(isCurrent);
      }
    } finally {
      // A history read failure must not leave an independently readable balance stale.
      if (isCurrent()) {
        await updateBalance(isCurrent: isCurrent);
      }
    }
  }

  Future<void> _runHistoryUpdate(
    bool Function() isCurrent,
    Future<void> Function() update,
  ) =>
      _historyUpdates.run(() async {
        if (!isCurrent()) return;
        try {
          await update();
          // Native deltas may already be acknowledged when a sync generation
          // changes. Recover with a snapshot rather than lose those updates.
          if (!isCurrent()) _historyNeedsReload = true;
        } catch (_) {
          // If transport/mapping fails after a native acknowledgement, reconcile
          // once on recovery. Never replace a successful snapshot with partial data.
          _historyNeedsReload = true;
          rethrow;
        }
      });

  Future<void> _updateHistoryChanges(bool Function() isCurrent, {List<String>? transactionIds}) =>
      _runHistoryUpdate(
          isCurrent, () => _loadHistoryChanges(isCurrent, transactionIds: transactionIds));

  Future<void> _loadHistoryChanges(bool Function() isCurrent,
      {List<String>? transactionIds}) async {
    if (_historyNeedsReload) {
      await _loadTransactions(isCurrent: isCurrent);
      return;
    }
    final changed = await _ffi!.getChangedTransactions(transactionIds: transactionIds);
    if (!isCurrent()) return;
    printV('Minotari history changes: ${changed.length} transactions');
    await transactionHistory.applyChanges(changed, _dtoToTransactionInfo, isCurrent: isCurrent);
  }

  Future<void> _stopSync() async {
    // A cancelled native forwarder may not have delivered its last committed
    // events. Reconcile once when this wallet reconnects, never on idle cycles.
    _historyNeedsReload = true;
    // Invalidate Dart results immediately, then cancel the native scan too.
    _balanceUpdates.invalidate();
    final opening = _openingCancelled;
    if (opening != null && !opening.isCompleted) opening.complete();
    final stopped = _syncLoop.stop();
    await _ffi?.stopScan();
    await stopped;
    await _balanceUpdates.idle;
    await _historyUpdates.idle;
  }

  /// Handle scan events from the scanner stream
  Future<void> _handleScanEvent(ScanEventDto event, bool Function() isCurrent) async {
    if (!isCurrent()) return;
    List<DisplayedTransactionDto>? changedTransactions;
    int? committedHeight;
    event.when(
      status: (status) {
        status.when(
          started: (accountId, fromHeight) {
            printV('Scan started from height: $fromHeight');
            _initialSyncHeight = fromHeight.toInt();
            syncStatus = SyncronizingSyncStatus();
          },
          progress: (accountId, currentHeight, blocksScanned) {
            printV('Scan progress: height $currentHeight, scanned $blocksScanned blocks');
            final currentHeightInt = currentHeight.toInt();
            committedHeight = currentHeightInt;

            if (_chainTipHeight > 0 && _chainTipHeight >= currentHeightInt) {
              syncStatus = SyncingSyncStatus.fromHeightValues(
                _chainTipHeight,
                _initialSyncHeight,
                currentHeightInt,
              );
            } else {
              syncStatus = SyncronizingSyncStatus();
            }
          },
          completed: (accountId, finalHeight, totalBlocksScanned) {
            _scanCompleted = true;
            printV('Scan completed at height $finalHeight, total blocks: $totalBlocksScanned');
          },
          paused: (accountId, lastScannedHeight, reason) {
            printV('Scan paused at height $lastScannedHeight: $reason');
          },
          waiting: (accountId, resumeInSeconds) {
            printV('Scanner waiting, resume in $resumeInSeconds seconds');
          },
          moreBlocksAvailable: (accountId, lastScannedHeight) {
            printV('More blocks available after height $lastScannedHeight');
          },
        );
      },
      transactionsReady: (dto) {
        printV('Transactions ready: ${dto.transactions.length} transactions');
        changedTransactions = dto.transactions;
      },
      transactionsUpdated: (dto) {
        printV('Transactions updated: ${dto.updatedTransactions.length} transactions');
        changedTransactions = dto.updatedTransactions;
      },
      error: (errorMessage) => throw StateError(errorMessage),
    );
    if (committedHeight != null) {
      // Upstream emits Progress after committing the batch. TransactionsReady
      // may arrive earlier and is not a safe boundary for a balance read.
      try {
        final refreshed = await _balanceUpdates.refresh(force: false, isCurrent: isCurrent);
        if (refreshed) {
          printV('Minotari balance refreshed during scan at height $committedHeight');
        }
      } catch (error) {
        // Keep the last valid balance and continue the scan; the next permitted
        // progress or the unconditional final refresh will retry this local read.
        printV('Minotari intermediate balance refresh will retry: $error');
      }
    }
    if (changedTransactions != null && changedTransactions!.isNotEmpty) {
      // Event payloads can contain upstream's raw outgoing amount/fee. Fetch only
      // dirty IDs through the same canonical mapper as the opening snapshot.
      await _updateHistoryChanges(isCurrent,
          transactionIds: changedTransactions!.map((tx) => tx.id).toList());
    }
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    final creds = credentials as MinotariTransactionCredentials;

    // Validate we have seed words
    final mnemonic = _mnemonic;
    if (mnemonic == null || mnemonic.isEmpty) {
      throw Exception('Wallet seed not available. Cannot create transaction.');
    }

    // Validate we have a connected node
    final currentNode = _currentNode;
    if (currentNode == null) {
      throw Exception('No node connected. Call connectToNode first.');
    }

    // Validate FFI is initialized
    final ffi = _ffi;
    if (ffi == null) {
      throw Exception('Wallet not initialized.');
    }

    // Get the first output (Minotari doesn't support multiple outputs yet)
    if (creds.outputs.length != 1) {
      throw Exception('Minotari requires exactly one recipient.');
    }

    final output = creds.outputs.first;
    final recipientAddress =
        output.isParsedAddress ? output.extractedAddress ?? output.address : output.address;

    final Money amount;
    if (output.sendAll) {
      throw UnsupportedError(
          'Send All is not supported by the current Minotari library: a change output is required.');
    } else {
      if (output.cryptoAmount.currency != CryptoCurrency.xtm) {
        throw ArgumentError('Minotari transactions require an XTM amount.');
      }
      amount = output.cryptoAmount;
    }

    if (amount.sign <= 0) {
      throw Exception('Invalid amount: $amount');
    }

    if (recipientAddress.isEmpty) {
      throw Exception('Recipient address is empty.');
    }

    // Prepare seed words as list
    final seedWords = mnemonic.split(' ').where((w) => w.isNotEmpty).toList();
    if (seedWords.length != 24) {
      throw Exception('Invalid seed: expected 24 words, got ${seedWords.length}');
    }

    final nodeUrl = currentNode.uri.toString();

    // Get note/payment ID if provided
    final note = output.note;
    final paymentId = (note != null && note.isNotEmpty) ? note : null;

    // Confirmation always uses a fresh quote for this immutable payment. A
    // failed estimate must prevent confirmation rather than substitute zero.
    final quote = await estimatePaymentFee(
      amount: amount.amount,
      priority: creds.priority,
      paymentId: paymentId,
    );
    final fee = Money(quote.estimatedFee, CryptoCurrency.xtm);
    final quotedGeneration = _historyGeneration;

    // Create the send transaction callback
    Future<String> sendTransactionCallback() async {
      if (_historyGeneration != quotedGeneration || _currentNode?.uri.toString() != nodeUrl) {
        throw StateError('Wallet or node changed. Review the payment again.');
      }
      final historyGeneration = _historyGeneration;
      bool isCurrent() => historyGeneration == _historyGeneration;
      final completer = Completer<String>();

      final stream = ffi.sendTransaction(
        seedWords: seedWords,
        passphrase: passphrase ?? '',
        recipientAddress: recipientAddress,
        amount: amount.amount,
        baseNodeUrl: nodeUrl,
        paymentId: paymentId,
        feePerGram: quote.feePerGram,
        maxFee: quote.estimatedFee,
      );

      stream.listen(
        (event) {
          printV('Send transaction stage: ${event.stage.name} - ${event.details}');

          if (event.stage == TransactionStage.completed) {
            // The details field contains the transaction ID on completion
            if (!completer.isCompleted) {
              completer.complete(event.details);
            }
          }
        },
        onError: (Object error) {
          printV('Send transaction error: $error');
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
        onDone: () {
          // If stream completes without reaching 'completed' stage, something went wrong
          if (!completer.isCompleted) {
            completer.completeError(Exception('Transaction stream ended unexpectedly'));
          }
        },
        cancelOnError: true,
      );

      // Wait for transaction to complete
      final txId = await completer.future;

      // The send is already recorded. A refresh failure must never invite a
      // second payment; the next scan recovers history with a full snapshot.
      try {
        if (isCurrent()) await updateBalance(isCurrent: isCurrent);
        if (isCurrent()) await _updateHistoryChanges(isCurrent);
      } catch (error) {
        _historyNeedsReload = true;
        printV('Send recorded; local refresh will retry: $error');
      }

      return txId;
    }

    return PendingMinotariTransaction(
      amount: amount,
      fee: fee,
      recipientAddress: recipientAddress,
      sendTransaction: () => MinotariRuntime.instance.run(sendTransactionCallback),
    );
  }

  @override
  Future<void> save() async {
    // Wallet state is saved automatically by the Rust layer
    // Save the keys file (mnemonic and passphrase)
    if (!(await WalletKeysFile.hasKeysFile(walletInfo.name, walletInfo.type))) {
      await saveKeysFile(password, encryptionFileUtils);
      await saveKeysFile(password, encryptionFileUtils, true); // backup
    }
  }

  @override
  Future<void> renameWalletFiles(String newWalletName) async {
    final currentWalletPath = await pathForWallet(name: walletInfo.name, type: walletInfo.type);
    final currentDirPath = await pathForWalletDir(name: walletInfo.name, type: walletInfo.type);

    final newWalletPath = await pathForWallet(name: newWalletName, type: walletInfo.type);

    printV(
        'renameWalletFiles from \"${walletInfo.name}\" (in ${currentWalletPath} ) to \"$newWalletName\"');
    final typeDir = await pathForWalletTypeDir(type: walletInfo.type);
    final ffi = MinotariFfi(dataPath: '$typeDir/wallet.db', walletName: walletInfo.name);
    await ffi.rename(newWalletName: newWalletName);

    final currentKeysFile = File('$currentWalletPath.keys');
    if (currentKeysFile.existsSync()) {
      await currentKeysFile.copy('$newWalletPath.keys');
    }

    final currentKeysBackupFile = File('$currentWalletPath.keys.backup');
    if (currentKeysBackupFile.existsSync()) {
      await currentKeysBackupFile.copy('$newWalletPath.keys.backup');
    }

    await Directory(currentDirPath).delete(recursive: true);
  }

  @override
  Future<void> changePassword(String password) async {
    // Minotari wallets don't use passwords in the traditional sense
    // The mnemonic is the key
  }

  @override
  Future<void> rescan({required int height}) async {
    await startSync();
  }

  @override
  Future<void> close({bool shouldCleanup = false}) async {
    _invalidateFee();
    _historyGeneration++;
    try {
      await _stopSync();
      await _ffi?.dispose();
    } finally {
      MinotariRuntime.instance.detach(this);
    }
  }

  @override
  int calculateEstimatedFee(TransactionPriority priority, int? amount) {
    if (amount == null ||
        BigInt.from(amount) != _cachedFeeAmount ||
        _mapPriorityToFeePriority(priority) != _cachedFeePriority) return 0;
    return _cachedFeeEstimate?.estimatedFee.toInt() ?? 0;
  }

  @override
  Future<void> updateEstimatedFeesParams(TransactionPriority? priority) async {
    // The generic hook has no amount. XTM uses estimatePaymentFee explicitly;
    // querying for zero here would select inputs for a different transaction.
  }

  Future<FeeEstimate> estimatePaymentFee({
    required BigInt amount,
    TransactionPriority? priority,
    String? paymentId,
  }) async {
    _invalidateFee();
    if (amount <= BigInt.zero || amount > (BigInt.one << 64) - BigInt.one) {
      throw ArgumentError('Minotari amount must be a positive uint64 in microTari.');
    }
    final ffi = _ffi;
    final node = _currentNode;
    if (ffi == null || node == null) {
      throw StateError('Wallet and node must be initialized to estimate a payment.');
    }
    final request = _feeRequest;
    final generation = _historyGeneration;
    final feePriority = _mapPriorityToFeePriority(priority);
    final key = (
      amount: amount,
      priority: feePriority,
      paymentId: paymentId?.isEmpty == true ? null : paymentId,
      url: node.uri.toString(),
    );
    _activeFeeKey = key;
    final quote = await ffi.estimateFee(
      amount: amount,
      priority: feePriority,
      baseNodeUrl: key.url,
      paymentId: key.paymentId,
    );
    if (generation != _historyGeneration ||
        node != _currentNode ||
        node.uri.toString() != key.url ||
        (request != _feeRequest && _activeFeeKey != key)) {
      throw StateError('The payment changed while estimating its fee.');
    }
    if (quote.estimatedFee <= BigInt.zero ||
        quote.feePerGram <= BigInt.zero ||
        quote.totalAmountRequired != amount + quote.estimatedFee) {
      throw StateError('Invalid Minotari fee estimate.');
    }
    // An identical preview may overlap confirmation. Return its independent
    // quote without letting an older completion replace the latest cache.
    if (request == _feeRequest) {
      _cachedFeeAmount = amount;
      _cachedFeePriority = feePriority;
      _cachedFeeEstimate = quote;
    }
    return quote;
  }

  /// Map Dart TransactionPriority to Rust FeePriority enum
  FeePriority _mapPriorityToFeePriority(TransactionPriority? priority) {
    if (priority is MinotariTransactionPriority) {
      switch (priority) {
        case MinotariTransactionPriority.slow:
          return FeePriority.slow;
        case MinotariTransactionPriority.medium:
          return FeePriority.medium;
        case MinotariTransactionPriority.fast:
          return FeePriority.fast;
      }
    }
    // Default to medium priority
    return FeePriority.medium;
  }

  /// Get the cached fee estimate (for display purposes)
  FeeEstimate? get cachedFeeEstimate => _cachedFeeEstimate;

  @override
  Future<bool> checkNodeHealth() async {
    final node = _currentNode;
    if (node == null) return false;

    try {
      final uri = node.uri;
      if (uri.host.isEmpty) return false;
      // Probe the selected RPC endpoint, not the locally stored wallet balance.
      // Native health checks use a short timeout and do not require a synced node.
      return await base_node.checkNodeHealth(baseUrl: uri.toString());
    } catch (e) {
      // URI/bridge failures must also reach Cake's health checker as a failed probe.
      printV('Minotari node health check failed: $e');
      return false;
    }
  }

  @override
  Future<Map<String, MinotariTransactionInfo>> fetchTransactions(
      {bool Function()? isCurrent}) async {
    final ffi = _ffi;
    if (ffi == null) return {};
    final txDtos = await fetchAllMinotariTransactionPages(ffi.getTransactions);

    return mapMinotariTransactions(txDtos, _dtoToTransactionInfo, isCurrent: isCurrent);
  }

  @override
  Future<String> signMessage(String message, {String? address}) async {
    final mnemonic = _mnemonic;
    if (mnemonic == null || mnemonic.trim().isEmpty) {
      throw StateError('A view-only wallet cannot sign messages.');
    }

    final signingAddress = address?.trim();
    if (signingAddress != null &&
        signingAddress.isNotEmpty &&
        signingAddress != walletAddresses.address) {
      throw ArgumentError('Minotari can only sign messages with this wallet\'s address.');
    }

    final seedWords = mnemonic.trim().split(RegExp(r'\s+'));
    if (seedWords.length != 24) {
      throw StateError('Invalid seed: expected 24 words, got ${seedWords.length}');
    }

    // The native adapter derives the same spend key as wallet creation/send.
    // A Tari passphrase encrypts the account at rest; it is not a signing input.
    return MinotariFfi.signMessage(message, seedWords: seedWords);
  }

  @override
  Future<bool> verifyMessage(String message, String signature, {String? address}) async {
    final verifyingAddress = address?.trim();
    if (verifyingAddress == null || verifyingAddress.isEmpty || signature.trim().isEmpty) {
      return false;
    }

    try {
      return await MinotariFfi.verifyMessage(message, signature.trim(), address: verifyingAddress);
    } catch (_) {
      // Match Cake's boolean verification contract for malformed addresses/signatures.
      return false;
    }
  }

  Future<MinotariBalance?> _readBalance() async {
    final data = await _ffi?.getBalance();
    if (data == null) {
      return null;
    }
    return MinotariBalance(
      available: data["available"]!,
      pendingIncoming: data["pendingIncoming"]!,
      pendingOutgoing: data["pendingOutgoing"]!,
    );
  }

  @override
  Future<void> updateBalance({bool Function()? isCurrent}) async {
    final generation = _historyGeneration;
    bool current() => generation == _historyGeneration && (isCurrent?.call() ?? true);
    try {
      await _balanceUpdates.refresh(isCurrent: current);
    } catch (e) {
      printV('Error updating balance: $e');
      if (isCurrent != null) rethrow;
    }
  }

  Future<void> updateTransactions({bool Function()? isCurrent}) {
    final generation = _historyGeneration;
    final current = isCurrent ?? () => generation == _historyGeneration;
    return _runHistoryUpdate(current, () => _loadTransactions(isCurrent: current));
  }

  Future<void> _loadTransactions({bool Function()? isCurrent}) async {
    if (_isTransactionUpdating) return;
    _isTransactionUpdating = true;
    try {
      final transactions = await fetchTransactions(isCurrent: isCurrent);
      if (isCurrent != null && !isCurrent()) return;
      transactionHistory.addMany(transactions);
      await transactionHistory.save();
      _historyNeedsReload = false;
      printV('Minotari history full load: ${transactions.length} transactions');
    } catch (e) {
      printV('Error updating transactions: $e');
      _historyNeedsReload = true;
      if (isCurrent != null) rethrow;
    } finally {
      _isTransactionUpdating = false;
    }
  }

  MinotariTransactionInfo _dtoToTransactionInfo(DisplayedTransactionDto txDto) {
    final direction = txDto.direction == DisplayedTransactionDirection.incoming
        ? TransactionDirection.incoming
        : TransactionDirection.outgoing;

    final isPending = minotariIsPending(txDto.status);
    final date = parseMinotariTransactionDate(txDto.blockchain.timestamp) ?? DateTime.now();
    final fee = txDto.fee?.amount.toInt();

    final txInfo = MinotariTransactionInfo(
      id: txDto.id,
      amount: txDto.amount.toInt(),
      date: date,
      direction: direction,
      isPending: isPending,
      fee: fee,
      height: txDto.blockchain.blockHeight.toInt(),
      confirmations: txDto.blockchain.confirmations.toInt(),
      payrefs: txDto.payrefs,
      isTestnet: isTestnet,
    );

    txInfo.additionalInfo['source'] = txDto.source.name;
    txInfo.additionalInfo['status'] = txDto.status.name;
    txInfo.additionalInfo['historyStatus'] = minotariHistoryStatus(txDto.status);
    // Presentation only: native status, isPending, confirmations and balances
    // remain unchanged until the scanner's confirmation monitor updates them.
    txInfo.additionalInfo['restoringHistory'] = _restoringHistory && isPending;
    txInfo.additionalInfo['amountDisplay'] = txDto.amountDisplay;

    if (txDto.message != null && txDto.message!.isNotEmpty) {
      txInfo.additionalInfo['message'] = txDto.message!;
    }

    if (txDto.fee != null) {
      txInfo.additionalInfo['feeDisplay'] = txDto.fee!.amountDisplay;
    }

    if (txDto.counterparty != null) {
      txInfo.additionalInfo['counterpartyAddress'] = txDto.counterparty!.address;
      txInfo.additionalInfo['counterpartyEmoji'] = txDto.counterparty!.addressEmoji;
    }

    return txInfo;
  }
}
