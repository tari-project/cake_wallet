import 'package:cw_core/payment_uris.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:mobx/mobx.dart';

part 'tari_ootle_wallet_addresses.g.dart';

class TariOotleWalletAddresses = TariOotleWalletAddressesBase with _$TariOotleWalletAddresses;

/// One account, one address, derived by the bridge from the seed.
abstract class TariOotleWalletAddressesBase extends WalletAddresses with Store {
  TariOotleWalletAddressesBase(super.walletInfo, super.isTestnet) : address = '';

  @override
  @observable
  String address;

  @override
  Future<void> init() async {}

  @override
  Future<void> updateAddressesInBox() async {}

  @override
  PaymentURI getPaymentUri(String amount) => TariOotleURI(amount: amount, address: address);
}
