import 'package:cw_tari_ootle/src/rust/api/wallet.dart';
import 'package:cw_tari_ootle/src/rust/frb_generated.dart';

export 'package:cw_tari_ootle/src/rust/api/wallet.dart' show TariOotleNetwork;

Future<void>? _init;

/// Loads `rust_lib_cw_tari_ootle` once per process. Every bridge call must await this first.
Future<void> initTariOotleLib() => _init ??= RustLib.init();

/// The network a WalletInfo.network name stands for. L1 and L2 use the same names.
TariOotleNetwork tariOotleNetworkByName(String? name) => TariOotleNetwork.values
    .firstWhere((n) => n.name == name, orElse: () => TariOotleNetwork.esmeralda);

/// The key an L1 burn must target so the owner of the L2 [address] can claim it.
/// Throws for anything that is not a valid Ootle address.
Future<String> tariOotleClaimPublicKey(String address) async {
  await initTariOotleLib();
  return claimPublicKeyFromAddress(address: address);
}

/// The L2 address of account 0 for [seedWords], the same words an L1 Minotari wallet uses.
Future<String> tariOotleAddressFromSeed(String seedWords, TariOotleNetwork network) async {
  await initTariOotleLib();
  return addressFromSeed(seedWords: seedWords, network: network);
}

/// Whether [address] is a valid Ootle address on [network].
Future<bool> tariOotleValidateAddress(String address, TariOotleNetwork network) async {
  await initTariOotleLib();
  return validateAddress(address: address, network: network);
}
