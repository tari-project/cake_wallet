import 'dart:async';
import 'dart:io';

import 'package:cake_wallet/core/key_service.dart';
import 'package:cake_wallet/core/wallet_loading_service.dart';
import 'package:cake_wallet/di.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/reactions/wallet_connect.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/utils/feature_flag.dart';
import 'package:cake_wallet/utils/tor.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cake_wallet/evm/evm.dart';

class BackgroundSync {
  BackgroundSync({bool Function()? isCancelled, Future<List<WalletInfo>> Function()? loadWallets})
      : _isCancelled = isCancelled ?? (() => false),
        _loadWallets = loadWallets ?? WalletInfo.getAll;

  final bool Function() _isCancelled;
  final Future<List<WalletInfo>> Function() _loadWallets;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  Future<void> _initializeNotifications() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(initializationSettings);
    _isInitialized = true;
  }

  Future<bool> requestPermissions() async {
    if (Platform.isIOS || Platform.isMacOS) {
      return await _notificationsPlugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(
                alert: true,
                badge: true,
                sound: true,
              ) ??
          false;
    } else if (Platform.isAndroid) {
      return await _notificationsPlugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.areNotificationsEnabled() ??
          false;
    }
    return false;
  }

  Future<void> showNotification(String title, String content) async {
    await _initializeNotifications();
    final hasPermission = await requestPermissions();

    if (!hasPermission) {
      printV('Notification permissions not granted');
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      'transactions',
      'Transactions',
      channelDescription: 'Channel for notifications about transactions',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    const iosDetails = DarwinNotificationDetails();

    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.hashCode,
      title,
      content,
      notificationDetails,
    );
  }

  Future<void> sync() async {
    if (_isCancelled()) return;
    final settingsStore = getIt.get<SettingsStore>();
    if (settingsStore.currentBuiltinTor) {
      printV("Starting Tor");
      await ensureTorStarted(context: null);
    }
    printV("Background sync started");
    await _syncWallets();
    printV("Background sync completed");
  }

  Future<void> _syncWallets() async {
    final walletLoadingService = getIt.get<WalletLoadingService>();
    final settingsStore = getIt.get<SettingsStore>();

    // A headless engine cannot use a view model whose constructor starts an
    // unawaited updateList(): it may still be empty when the Worker runs.
    final wallets = (await _loadWallets())
        .where((element) => !element.isHardwareWallet)
        .where((element) => ![WalletType.haven, WalletType.decred].contains(element.type))
        .toList();
    for (int i = 0; i < wallets.length; i++) {
      if (_isCancelled()) break;
      final wallet =
          await walletLoadingService.load(wallets[i].type, wallets[i].name, isBackground: true);
      int syncedTicks = 0;
      final keyService = getIt.get<KeyService>();

      int stuckTicks = 0;

      try {
        inner:
        while (!_isCancelled()) {
          await Future.delayed(const Duration(seconds: 1));
          if (_isCancelled()) break inner;
          final syncStatus = wallet.syncStatus;
          final progress = syncStatus.progress();
          // Done for this slot without being synced: the wallet's time budget ran out (the next
          // slot resumes) or the app is syncing it. Don't reconnect or count it as stuck.
          if (syncStatus is PausedSyncStatus || syncStatus is HandledByForegroundSyncStatus) {
            printV("${wallet.name} $syncStatus");
            break inner;
          }
          // A failed wallet is skipped after the same grace period instead of looping forever.
          if (syncStatus is ConnectedSyncStatus ||
              syncStatus is AttemptingSyncStatus ||
              syncStatus is NotConnectedSyncStatus ||
              syncStatus is FailedSyncStatus) {
            stuckTicks++;
            if (stuckTicks > 30) {
              printV("${wallet.name} STUCK SYNCING");
              break inner;
            }
          } else {
            stuckTicks = 0;
          }
          if (syncStatus is NotConnectedSyncStatus) {
            printV("${wallet.name} NOT CONNECTED");

            int? chainId;
            if (isEVMCompatibleChain(wallet.type)) {
              chainId = evm!.getSelectedChainId(wallet);
            }

            final node = settingsStore.getCurrentNode(wallet.type, chainId: chainId);
            await wallet.connectToNode(node: node);
            await wallet.startBackgroundSync();
            printV("STARTED SYNC");
            continue inner;
          }

          if (progress > 0.999 || syncStatus is SyncedSyncStatus) {
            syncedTicks++;
            if (syncedTicks > 5) {
              syncedTicks = 0;
              printV("WALLET $i SYNCED");
              break inner;
            }
          } else {
            syncedTicks = 0;
          }
          if (FeatureFlag.hasDevOptions) {
            if (syncStatus is SyncingSyncStatus) {
              final blocksLeft = syncStatus.blocksLeft;
              printV("$blocksLeft Blocks Left");
            } else if (syncStatus is SyncedSyncStatus) {
              printV("Synced");
            } else if (syncStatus is SyncedTipSyncStatus) {
              printV("Scanned Tip: ${syncStatus.tip}");
            } else if (syncStatus is NotConnectedSyncStatus) {
              printV("Still Not Connected");
            } else if (syncStatus is AttemptingSyncStatus) {
              printV("Attempting Sync");
            } else if (syncStatus is StartingScanSyncStatus) {
              printV("Starting Scan");
            } else if (syncStatus is SyncronizingSyncStatus) {
              printV("Syncronizing");
            } else if (syncStatus is FailedSyncStatus) {
              printV("Failed Sync");
            } else if (syncStatus is ConnectingSyncStatus) {
              printV("Connecting");
            } else {
              printV("Unknown Sync Status ${syncStatus.runtimeType}");
            }
          }
        }
        if (_isCancelled()) return;
        final txs = wallet.transactionHistory;
        final sortedTxs = txs.transactions.values.toList()
          ..sort((a, b) => a.date.compareTo(b.date));
        final sharedPreferences = await SharedPreferences.getInstance();
        for (final tx in sortedTxs) {
          final lastTriggerString =
              sharedPreferences.getString(PreferencesKey.backgroundSyncLastTrigger(wallet.name));
          final lastTriggerDate =
              lastTriggerString != null ? DateTime.parse(lastTriggerString) : DateTime.now();
          final keys = sharedPreferences.getKeys();
          if (tx.date.isBefore(lastTriggerDate)) {
            printV(
                "w: ${wallet.name}, tx: ${tx.date} is before $lastTriggerDate (lastTriggerString: $lastTriggerString) (k: ${keys.length})");
            continue;
          }
          await sharedPreferences.setString(PreferencesKey.backgroundSyncLastTrigger(wallet.name),
              tx.date.add(Duration(minutes: 1)).toIso8601String());
          final action = tx.additionalInfo['isAutoShield'] == true
              ? "Autoshield"
              : tx.direction == TransactionDirection.incoming
                  ? "Received"
                  : "Sent";
          if (sharedPreferences.getBool(PreferencesKey.backgroundSyncNotificationsEnabled) ??
              false) {
            await showNotification(
                "$action ${wallet.currency.fullName} in ${wallet.name}", "${tx.amount.toString()}");
          }
          printV(
              "${wallet.currency.fullName} in ${wallet.name}: TX: ${tx.date} ${tx.amount} ${tx.direction}");
        }
      } finally {
        try {
          await wallet
              .stopBackgroundSync(await keyService.getWalletPassword(walletName: wallet.name));
        } finally {
          await wallet.close(shouldCleanup: true);
        }
      }
    }
  }
}
