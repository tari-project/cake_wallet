import 'dart:io';

import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_credentials.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_keys_file.dart';
import 'package:cw_core/wallet_service.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_tari_ootle/src/rust/api/wallet.dart' as bridge;
import 'package:cw_tari_ootle/tari_ootle_ffi.dart';
import 'package:cw_tari_ootle/tari_ootle_wallet.dart';

final _encryptionFileUtils = encryptionFileUtilsFor(true);

/// Esmeralda is the only Ootle network with a public indexer; switch to [TariOotleNetwork.mainNet]
/// for non-testnet wallets once a mainnet indexer exists. Existing wallets keep the network stored
/// in their WalletInfo.
const _defaultNetwork = TariOotleNetwork.esmeralda;

class TariOotleWalletService extends WalletService<TariOotleNewWalletCredentials,
    TariOotleRestoreWalletFromSeedCredentials, WalletCredentials, WalletCredentials> {
  @override
  WalletType getType() => WalletType.tari;

  @override
  Future<WalletBase> create(TariOotleNewWalletCredentials credentials, {bool? isTestnet}) async {
    await initTariOotleLib();
    final created = await bridge.createWallet(network: _defaultNetwork);
    return _createWallet(credentials, created.seedWords, isNewWallet: true);
  }

  @override
  Future<WalletBase> restoreFromSeed(TariOotleRestoreWalletFromSeedCredentials credentials,
      {bool? isTestnet}) async {
    await initTariOotleLib();
    // Rejects words that are not a valid CipherSeed before anything is written.
    await bridge.addressFromSeed(seedWords: credentials.mnemonic, network: _defaultNetwork);
    return _createWallet(credentials, credentials.mnemonic, isNewWallet: false);
  }

  Future<TariOotleWallet> _createWallet(WalletCredentials credentials, String mnemonic,
      {required bool isNewWallet}) async {
    final walletInfo = credentials.walletInfo!;
    walletInfo.network = _defaultNetwork.name;
    walletInfo.restoreHeight = 0;
    await walletInfo.save();

    final wallet = TariOotleWallet(
      walletInfo,
      await walletInfo.getDerivationInfo(),
      mnemonic: mnemonic,
      password: credentials.password!,
      network: _defaultNetwork,
      encryptionFileUtils: _encryptionFileUtils,
      isNewWallet: isNewWallet,
    );
    await wallet.init();
    await wallet.save();
    return wallet;
  }

  @override
  Future<WalletBase> openWallet(String name, String password) async {
    final walletInfo = await WalletInfo.get(name, getType());
    if (walletInfo == null) throw Exception('Wallet not found');

    final keys =
        await WalletKeysFile.readKeysFile(name, getType(), password, _encryptionFileUtils);
    final wallet = TariOotleWallet(
      walletInfo,
      await walletInfo.getDerivationInfo(),
      mnemonic: keys.mnemonic!,
      password: password,
      network: TariOotleNetwork.values.byName(walletInfo.network ?? _defaultNetwork.name),
      encryptionFileUtils: _encryptionFileUtils,
    );
    await wallet.init();
    return wallet;
  }

  @override
  Future<void> remove(String wallet) async {
    await initTariOotleLib();
    await bridge.closeWallet(name: wallet);
    final dir = Directory(await pathForWalletDir(name: wallet, type: getType()));
    if (dir.existsSync()) await dir.delete(recursive: true);

    final walletInfo = await WalletInfo.get(wallet, getType());
    if (walletInfo != null) await WalletInfo.delete(walletInfo);
  }

  /// The bridge names its state file after the wallet, so it moves along with the keys.
  @override
  Future<void> rename(String currentName, String password, String newName) async {
    await initTariOotleLib();
    await bridge.closeWallet(name: currentName);
    await super.rename(currentName, password, newName);
    final dir = await pathForWalletDir(name: newName, type: getType());
    final state = File('$dir/$currentName.ootle.json');
    if (state.existsSync()) await state.rename('$dir/$newName.ootle.json');
  }

  @override
  Future<bool> isWalletExit(String name) async =>
      File('${await pathForWallet(name: name, type: getType())}.keys').existsSync();

  @override
  Future<WalletBase> restoreFromKeys(WalletCredentials credentials, {bool? isTestnet}) =>
      throw UnimplementedError('Tari Ootle wallets restore from seed only');

  @override
  Future<WalletBase> restoreFromHardwareWallet(WalletCredentials credentials) =>
      throw UnimplementedError('Tari Ootle has no hardware wallet support');
}

class TariOotleNewWalletCredentials extends WalletCredentials {
  TariOotleNewWalletCredentials({required super.name, super.password, super.walletInfo});
}

class TariOotleRestoreWalletFromSeedCredentials extends WalletCredentials {
  TariOotleRestoreWalletFromSeedCredentials({
    required super.name,
    required String super.password,
    required this.mnemonic,
    super.walletInfo,
  });

  final String mnemonic;
}
