import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/minotari/minotari.dart';
import 'package:cake_wallet/new-ui/widgets/new_primary_button.dart';
import 'package:cake_wallet/new-ui/widgets/receive_page/receive_top_bar.dart';
import 'package:cake_wallet/src/widgets/alert_with_two_actions.dart';
import 'package:cake_wallet/tari_ootle/tari_ootle.dart';
import 'package:cake_wallet/utils/show_pop_up.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// TODO: move the copy on this page and the claim page into the .arb files.

/// Burns XTM on the Minotari (L1) wallet so a Tari Ootle (L2) account can claim it.
class TariBurnPage extends StatefulWidget {
  const TariBurnPage({super.key, required this.wallet});

  final WalletBase wallet;

  @override
  State<TariBurnPage> createState() => _TariBurnPageState();
}

class _TariBurnPageState extends State<TariBurnPage> {
  final _address = TextEditingController();
  final _amount = TextEditingController();
  String? _seedAddress;
  String? _error;
  String? _progress;
  bool _busy = false;
  List<MinotariBurn> _burns = [];
  String? _burnsError;

  Money get _available =>
      widget.wallet.balance[CryptoCurrency.xtm]?.available ?? Money.zero(CryptoCurrency.xtm);

  @override
  void initState() {
    super.initState();
    _prefillAddress();
    _loadBurns();
  }

  /// A Tari wallet restored from these same words has this address; that is the usual target.
  Future<void> _prefillAddress() async {
    final seed = widget.wallet.seed;
    if (seed == null || seed.isEmpty) return;
    try {
      final address =
          await tariOotle!.addressFromSeed(seed, widget.wallet.walletInfo.network);
      if (!mounted) return;
      setState(() {
        _seedAddress = address;
        if (_address.text.isEmpty) _address.text = address;
      });
    } catch (_) {
      // Words the L2 bridge can't read: the user types an address instead.
    }
  }

  Future<void> _loadBurns() async {
    try {
      final burns = await minotari!.getBurns(widget.wallet);
      if (!mounted) return;
      setState(() {
        _burns = burns;
        _burnsError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _burnsError = e.toString());
    }
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final address = _address.text.trim();
    final amount = Money.tryParse(_amount.text.trim().replaceAll(',', '.'), CryptoCurrency.xtm);

    if (!await tariOotle!.validateAddress(address, widget.wallet.walletInfo.network)) {
      return setState(() => _error = 'Enter a Tari L2 address (otl_...) for this network.');
    }
    if (amount == null || amount.amount <= BigInt.zero) {
      return setState(() => _error = 'Enter an amount above zero.');
    }
    if (amount.amount > _available.amount) {
      return setState(() => _error = 'The amount is more than the available balance.');
    }

    setState(() => _busy = true);
    try {
      final claimKey = await tariOotle!.claimPublicKeyFromAddress(address);
      final fee = Money.fromInt(
          await minotari!.estimateBurnFee(widget.wallet, amount.amount.toInt()),
          CryptoCurrency.xtm);
      if (!mounted) return;
      if (!await _confirm(address, amount, fee)) return;
      await for (final message in minotari!.burnToL2(widget.wallet,
          claimPublicKey: claimKey, amount: amount.amount.toInt())) {
        if (mounted) setState(() => _progress = message);
      }
      if (!mounted) return;
      setState(() {
        _progress = 'Burn recorded. Once it has 3 confirmations, claim it from the Tari wallet '
            'that owns $address. Do not burn again.';
        _amount.clear();
      });
      await _loadBurns();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _progress = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String address, Money amount, Money fee) async {
    final ok = await showPopUp<bool>(
      context: context,
      builder: (dialogContext) => AlertWithTwoActions(
        alertTitle: 'Burn ${amount.toStringWithSymbol()}?',
        alertContent: 'Fee: about ${fee.toStringWithSymbol()}\n\nTo: $address\n\n'
            'A burn is irreversible. The XTM is destroyed on L1 and only the owner of this '
            'Tari L2 address can claim it. Funds burned to the wrong address are lost.',
        leftButtonText: 'Cancel',
        rightButtonText: 'Burn',
        actionLeftButton: () => Navigator.of(dialogContext).pop(false),
        actionRightButton: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    return ok ?? false;
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null) _address.text = text.trim();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      child: Container(
        color: scheme.surface,
        child: SafeArea(
          child: Column(children: [
            ModalTopBar(
              title: 'Move to Tari L2',
              leadingIcon: Icon(Icons.arrow_back_ios_new),
              leadingSemanticLabel: S.of(context).seed_alert_back,
              onLeadingPressed: Navigator.of(context).pop,
              trailingIcon: Icon(Icons.refresh),
              trailingSemanticLabel: 'Refresh',
              onTrailingPressed: _loadBurns,
            ),
            Expanded(
              child: ListView(padding: EdgeInsets.all(16), children: [
                Text('Burn XTM on Minotari (L1) so a Tari Ootle (L2) wallet can claim the same '
                    'amount as TARI.'),
                SizedBox(height: 16),
                TextField(
                  key: ValueKey('tari_burn_address'),
                  controller: _address,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Tari L2 address',
                    helperText: _seedAddress != null && _address.text == _seedAddress
                        ? 'The Tari wallet from this wallet\'s seed words'
                        : null,
                    suffixIcon: IconButton(icon: Icon(Icons.paste), onPressed: _paste),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: 16),
                TextField(
                  key: ValueKey('tari_burn_amount'),
                  controller: _amount,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount (XTM)',
                    helperText: 'Available: ${_available.toStringWithSymbol()}',
                  ),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    'Burns are irreversible. Only the owner of the Tari L2 address can claim '
                    'the funds, after the burn has 3 confirmations on L1.',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
                if (_error != null) ...[
                  SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                if (_progress != null) ...[SizedBox(height: 12), Text(_progress!)],
                SizedBox(height: 24),
                Text('Your burns', style: Theme.of(context).textTheme.titleMedium),
                if (_burnsError != null)
                  Text(_burnsError!, style: TextStyle(color: scheme.error))
                else if (_burns.isEmpty)
                  Text('None yet', style: TextStyle(color: scheme.onSurfaceVariant))
                else
                  for (final burn in _burns.reversed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(Money.fromInt(burn.amount, CryptoCurrency.xtm)
                          .toStringWithSymbol()),
                      subtitle: Text(burn.isReady
                          ? 'Proof ready: claim it from the Tari wallet'
                          : burn.pendingReason ?? 'Pending'),
                    ),
              ]),
            ),
            Padding(
              padding: EdgeInsets.all(16),
              child: NewPrimaryButton(
                onPressed: _submit,
                text: 'Burn to Tari L2',
                color: scheme.primary,
                textColor: scheme.onPrimary,
                isLoading: _busy,
                disabled: _busy,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
