import 'dart:async';

import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_minotari/minotari_native_logger.dart';
import 'package:cw_minotari/minotari_runtime.dart';
import 'package:cw_minotari/src/rust/api/wallet.dart'
    show
        WalletCreationDetails,
        createWallet,
        restoreWallet,
        importViewOnlyWallet,
        renameWallet,
        listWallets,
        deleteWallet;
import 'package:cw_minotari/src/rust/api/balance.dart' as balance;
import 'package:cw_minotari/src/rust/api/address.dart' as address;
import 'package:cw_minotari/src/rust/api/db.dart';
import 'package:cw_minotari/src/rust/api/fee.dart' as fee;
import 'package:cw_minotari/src/rust/api/scanner.dart' as scanner;
import 'package:cw_minotari/src/rust/api/transactions.dart' as transactions;
import 'package:cw_minotari/src/rust/api/send_transaction.dart' as send_tx;
import 'package:cw_minotari/src/rust/api/network.dart';
import 'package:cw_minotari/src/rust/api/signing.dart' as signing;
import 'package:cw_minotari/src/rust/frb_generated.dart';

export 'package:cw_minotari/src/rust/api/send_transaction.dart'
    show SendTransactionEvent, TransactionStage;

export 'package:cw_minotari/src/rust/api/fee.dart' show FeeEstimate, FeePriority;

/// FFI interface for Minotari wallet using Flutter Rust Bridge
/// Note: The Rust library uses "password" parameter name but it actually means
/// BIP39 passphrase for seed derivation. We use "passphrase" in our Dart code
/// for clarity.
class MinotariFfi {
  final String walletName;
  final String dataPath;
  TariNetwork? _networkInternal;
  bool _isInitialized = false;
  Future<void>? _nativeScanDone;

  static int? _dbEpoch;
  static String? _dbPath;
  static Future<void>? _rustLibInitialization;
  static final _nativeLogger = MinotariNativeLogger();

  MinotariFfi({required this.dataPath, required this.walletName});

  /// Get the network, throws if wallet not initialized
  TariNetwork get _network {
    if (_networkInternal == null) {
      throw Exception('Wallet not initialized - network not set');
    }
    return _networkInternal!;
  }

  static Future<void> _ensureRustLibInitialized() async {
    // Use the bridge's state, including when the app/test initialized it first.
    // ignore: invalid_use_of_internal_member
    if (!RustLib.instance.initialized) {
      final initialization = _rustLibInitialization ??= RustLib.init();
      try {
        await initialization;
      } finally {
        if (identical(_rustLibInitialization, initialization)) {
          _rustLibInitialization = null;
        }
      }
    }
    await _nativeLogger.ensureInitialized();
  }

  /// Off-chain signing needs only the seed; it never opens the shared database.
  static Future<String> signMessage(String message, {required List<String> seedWords}) async {
    await _ensureRustLibInitialized();
    return signing.signMessage(message: message, seedWords: seedWords);
  }

  /// Verification is also available without an open or spend-capable wallet.
  static Future<bool> verifyMessage(
    String message,
    String signature, {
    required String address,
  }) async {
    await _ensureRustLibInitialized();
    return signing.verifyMessage(message: message, signature: signature, address: address);
  }

  /// Reinitializes the shared database when ownership returns from another engine.
  static Future<void> _ensureDbInitialized({required String path}) async {
    final runtime = MinotariRuntime.instance;
    await runtime.ensureSession();
    if (_dbEpoch != runtime.epoch || _dbPath != path) {
      try {
        await runtime.run(() => initializeDatabase(path: path));
        _dbEpoch = runtime.epoch;
        _dbPath = path;
      } catch (_) {
        runtime.releaseIfIdle();
        rethrow;
      }
    }
  }

  void _ensureWalletInitialized() {
    if (!_isInitialized ||
        !MinotariRuntime.instance.ownsNative ||
        _dbEpoch != MinotariRuntime.instance.epoch ||
        _dbPath != dataPath) {
      throw Exception('Wallet not initialized');
    }
  }

  /// Another engine may have used the native DB while the UI was suspended.
  Future<void> resume() async {
    if (!_isInitialized) throw StateError('Wallet not initialized');
    await _ensureDbInitialized(path: dataPath);
  }

  Future<WalletCreationDetails> _initializeAccount(
      Future<WalletCreationDetails> Function() operation) async {
    try {
      return await MinotariRuntime.instance.run(operation);
    } catch (_) {
      MinotariRuntime.instance.releaseIfIdle();
      rethrow;
    }
  }

  /// Open an existing wallet
  Future<void> open(TariNetwork network) async {
    await _ensureRustLibInitialized();

    printV('[MinotariFfi] Opening wallet "$walletName" at path: $dataPath');
    try {
      await _ensureDbInitialized(path: dataPath);
      printV('[MinotariFfi] Database initialized successfully for wallet "$walletName"');
    } catch (e) {
      printV('[MinotariFfi] Failed to initialize database: $e');
      rethrow;
    }

    _networkInternal = network;
    _isInitialized = true;
  }

  /// Create a new wallet
  /// Rust generates mnemonic internally
  /// Returns WalletCreationDetails which contains seed words
  /// [passphrase] is the BIP39 passphrase for seed derivation
  Future<WalletCreationDetails> create(TariNetwork network, {required String passphrase}) async {
    await _ensureRustLibInitialized();

    await _ensureDbInitialized(path: dataPath);

    final details = await _initializeAccount(
        () => createWallet(walletName: walletName, network: network, passphrase: passphrase));

    _networkInternal = network;
    _isInitialized = true;

    return details;
  }

  /// Restore wallet from mnemonic
  /// Returns WalletCreationDetails which contains seed words
  /// [passphrase] is the BIP39 passphrase for seed derivation
  Future<WalletCreationDetails> restore(
    String mnemonic,
    TariNetwork network, {
    required String passphrase,
  }) async {
    await _ensureRustLibInitialized();

    await _ensureDbInitialized(path: dataPath);

    // Convert mnemonic string to list of words
    final seedWords = mnemonic.split(' ').where((word) => word.isNotEmpty).toList();

    if (seedWords.length != 24) {
      MinotariRuntime.instance.releaseIfIdle();
      throw Exception('Invalid mnemonic: expected 24 words, got ${seedWords.length}');
    }

    final details = await _initializeAccount(() => restoreWallet(
          walletName: walletName,
          seedWords: seedWords,
          passphrase: passphrase,
          network: network,
        ));

    _networkInternal = network;
    _isInitialized = true;

    return details;
  }

  /// Import a view-only wallet from keys
  /// [viewPrivateKeyHex] - the private view key in hex
  /// [spendPublicKeyHex] - the public spend key in hex
  /// [birthday] - block height to start scanning from (like restore height)
  /// [passphrase] - BIP39 passphrase for key derivation
  Future<WalletCreationDetails> importViewOnly({
    required String viewPrivateKeyHex,
    required String spendPublicKeyHex,
    required int birthday,
    required String passphrase,
    required TariNetwork network,
  }) async {
    await _ensureRustLibInitialized();

    await _ensureDbInitialized(path: dataPath);

    final details = await _initializeAccount(() => importViewOnlyWallet(
          walletName: walletName,
          viewPrivateKeyHex: viewPrivateKeyHex,
          spendPublicKeyHex: spendPublicKeyHex,
          birthday: birthday,
          passphrase: passphrase,
          network: network,
        ));

    _networkInternal = network;
    _isInitialized = true;

    return details;
  }

  /// Rename this wallet (updates internal state in the SQLite DB)
  /// Does not require the wallet to be open — only the Rust library needs to be initialized.
  Future<void> rename({required String newWalletName}) async {
    await _ensureRustLibInitialized();
    await _ensureDbInitialized(path: dataPath);

    printV("[MinotariFfi] Renaming wallet from \"$walletName\" to \"$newWalletName\"");
    try {
      await MinotariRuntime.instance
          .run(() => renameWallet(currentWalletName: walletName, newWalletName: newWalletName));
    } finally {
      MinotariRuntime.instance.releaseIfIdle();
    }
  }

  /// Remove only this account from the shared database, without opening it or
  /// stopping another wallet's scanner. Missing accounts allow cleanup to resume
  /// after native deletion succeeded but file/metadata deletion failed.
  Future<void> remove() async {
    await _ensureRustLibInitialized();
    await _ensureDbInitialized(path: dataPath);
    try {
      await MinotariRuntime.instance.run(() async {
        if ((await listWallets()).contains(walletName)) {
          await deleteWallet(walletName: walletName);
        }
      });
    } finally {
      MinotariRuntime.instance.releaseIfIdle();
    }
  }

  /// Get wallet address
  /// [passphrase] is the BIP39 passphrase for seed derivation
  Future<String> getAddress({required String passphrase}) async {
    _ensureWalletInitialized();

    return await MinotariRuntime.instance.run(() => address.getAddress(
          walletName: walletName,
          passphrase: passphrase,
          network: _network,
        ));
  }

  /// Get wallet balance
  Future<Map<String, int>> getBalance() async {
    _ensureWalletInitialized();

    printV('[MinotariFfi] Getting balance for wallet "$walletName"');
    final balanceData =
        await MinotariRuntime.instance.run(() => balance.getBalance(walletName: walletName));
    printV('[MinotariFfi] Balance retrieved successfully for wallet "$walletName"');

    // Convert BigInt to int (Minotari uses micro-tari, which fits in int64)
    return {
      'available': balanceData.available.toInt(),
      'pendingIncoming': balanceData.unconfirmed.toInt(),
      'pendingOutgoing': balanceData.locked.toInt(),
    };
  }

  /// Start scanner-based blockchain sync
  /// Returns a stream of scan events for progress updates and transaction discovery
  /// [passphrase] is the BIP39 passphrase for seed derivation
  Stream<scanner.ScanEventDto> startScan({
    required String baseNodeAddress,
    required String passphrase,
    bool continuous = false,
    int batchSize = 25,
    int pollIntervalSeconds = 60,
    int requiredConfirmations = 3, // Default to 3 confirmations for transaction discovery
  }) {
    _ensureWalletInitialized();

    final config = scanner.ScanConfiguration(
      walletName: walletName,
      passphrase: passphrase,
      baseUrl: baseNodeAddress,
      batchSize: BigInt.from(batchSize),
      continuous: continuous,
      pollIntervalSeconds: BigInt.from(pollIntervalSeconds),
      requiredConfirmations: BigInt.from(requiredConfirmations),
    );

    final done = Completer<void>();
    // Cancelling a Dart subscription does not join the Rust scan. Keep its raw
    // stream alive until Rust returns, and retain ownership for that whole time.
    var forwarding = true;
    late StreamController<scanner.ScanEventDto> controller;
    controller = StreamController<scanner.ScanEventDto>(
      onListen: () {
        _nativeScanDone = MinotariRuntime.instance.run(() {
          scanner.startScan(config: config).listen(
            (event) {
              if (forwarding) controller.add(event);
            },
            onError: (Object error, StackTrace stack) {
              if (forwarding) controller.addError(error, stack);
            },
            onDone: () {
              done.complete();
              unawaited(controller.close());
            },
          );
          return done.future;
        }).catchError((Object error, StackTrace stack) {
          if (forwarding && !controller.isClosed) controller.addError(error, stack);
          unawaited(controller.close());
        });
      },
      onCancel: () async {
        forwarding = false;
        await stopScan();
      },
    );
    return controller.stream;
  }

  /// Stop the currently running scan
  Future<void> stopScan() async {
    // A stale UI handle must not cancel the background engine's scanner.
    if (MinotariRuntime.instance.ownsNative) {
      await scanner.stopScan();
      await _nativeScanDone;
    }
  }

  Future<List<transactions.DisplayedTransactionDto>> getChangedTransactions(
      {List<String>? transactionIds}) async {
    _ensureWalletInitialized();
    return await MinotariRuntime.instance.run(() => transactions.getChangedTransactions(
        walletName: walletName, transactionIds: transactionIds));
  }

  /// Get transaction history from the wallet
  Future<List<transactions.DisplayedTransactionDto>> getTransactions({
    int limit = 100,
    int offset = 0,
  }) async {
    _ensureWalletInitialized();

    return await MinotariRuntime.instance.run(() => transactions.getTransactions(
          walletName: walletName,
          limit: limit,
          offset: offset,
        ));
  }

  /// Send a transaction to the specified recipient
  /// Returns a stream of transaction events for progress updates
  ///
  /// [seedWords] - The wallet's mnemonic seed words (24 words)
  /// [passphrase] - BIP39 passphrase for seed derivation
  /// [recipientAddress] - The Tari address to send to
  /// [amount] - Amount in microTari
  /// [baseNodeUrl] - The base node URL for broadcasting
  /// [paymentId] - Optional payment ID/message
  Stream<send_tx.SendTransactionEvent> sendTransaction({
    required List<String> seedWords,
    required String passphrase,
    required String recipientAddress,
    required BigInt amount,
    required String baseNodeUrl,
    String? paymentId,
    required BigInt feePerGram,
    required BigInt maxFee,
  }) {
    _ensureWalletInitialized();

    final details = send_tx.SendTransactionDetails(
      seedWords: seedWords,
      passphrase: passphrase,
      network: _network,
      baseUrl: baseNodeUrl,
      walletName: walletName,
      recipientAddress: recipientAddress,
      amount: amount,
      paymentId: paymentId,
    );

    return send_tx.sendTransactionWithFee(
      details: details,
      feePerGram: feePerGram,
      maxFee: maxFee,
    );
  }

  /// Estimate transaction fee based on amount and priority
  ///
  /// [amount] - Amount in microTari to send
  /// [priority] - Fee priority (slow, medium, fast)
  /// [baseNodeUrl] - The base node URL for fee estimation
  Future<fee.FeeEstimate> estimateFee({
    required BigInt amount,
    required fee.FeePriority priority,
    required String baseNodeUrl,
    String? paymentId,
  }) async {
    _ensureWalletInitialized();

    return await MinotariRuntime.instance.run(() => fee.estimatePaymentFee(
          amount: amount,
          priority: priority,
          baseUrl: baseNodeUrl,
          walletName: walletName,
          paymentId: paymentId,
        ));
  }

  /// Dispose of the wallet handle
  /// Note: We don't call disconnectDatabase() here because it breaks re-initialization
  /// The Rust library handles database connection switching internally via initializeDatabase()
  Future<void> dispose() async {
    printV('[MinotariFfi] Disposing wallet "$walletName" (was initialized: $_isInitialized)');
    if (_isInitialized) {
      _isInitialized = false;
      _networkInternal = null;
    }
    MinotariRuntime.instance.releaseIfIdle();
  }
}
