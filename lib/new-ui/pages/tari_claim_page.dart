import 'package:cake_wallet/generated/i18n.dart';
import 'dart:io';

import 'package:cake_wallet/new-ui/widgets/new_primary_button.dart';
import 'package:cake_wallet/new-ui/widgets/receive_page/receive_top_bar.dart';
import 'package:cake_wallet/tari_ootle/tari_ootle.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter/material.dart';

/// Claims Minotari (L1) burns into a Tari Ootle (L2) wallet.
///
/// Proofs come from the Minotari wallets on this device, which save each confirmed burn as
/// `<minotari dir>/burn_proofs/<claim public key>-<commitment>.json`, or are pasted by hand
/// (proofs from Tari Universe or minotari-cli).
class TariClaimPage extends StatefulWidget {
  const TariClaimPage({super.key, required this.wallet});

  final WalletBase wallet;

  @override
  State<TariClaimPage> createState() => _TariClaimPageState();
}

class _TariClaimPageState extends State<TariClaimPage> {
  final _pasted = TextEditingController();
  List<TariOotleClaim> _claims = [];
  final Map<String, String> _importErrors = {};
  String? _pasteError;
  String? _loadError;
  int? _epoch;
  bool _loading = true;
  String? _claiming;
  final Map<String, String> _progress = {};

  String? get _claimKey => tariOotle!.claimPublicKey(widget.wallet);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final key = _claimKey;
    if (key != null) {
      await _importDeviceProofs(key);
      try {
        final claims = await tariOotle!.getClaims(widget.wallet);
        _claims = claims;
        _loadError = null;
      } catch (e) {
        _loadError = e.toString();
      }
      try {
        _epoch = await tariOotle!.currentEpoch(widget.wallet);
      } catch (_) {
        _epoch = null;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Adds every proof a Minotari wallet on this device saved for this wallet's key.
  Future<void> _importDeviceProofs(String key) async {
    final dir = Directory('${await pathForWalletTypeDir(type: WalletType.minotari)}/burn_proofs');
    _importErrors.clear();
    if (!dir.existsSync()) return;
    for (final file in dir.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (!name.toLowerCase().startsWith(key.toLowerCase()) || !name.endsWith('.json')) continue;
      try {
        await tariOotle!.addBurnProof(widget.wallet, await file.readAsString());
      } catch (e) {
        _importErrors[name] = _message(e);
      }
    }
  }

  Future<void> _addPasted() async {
    setState(() => _pasteError = null);
    try {
      await tariOotle!.addBurnProof(widget.wallet, _pasted.text.trim());
      _pasted.clear();
      await _load();
    } catch (e) {
      final message = _message(e);
      setState(() => _pasteError =
          message.startsWith('Invalid burn proof') ? message : 'Not a burn proof: $message');
    }
  }

  Future<void> _claim(TariOotleClaim claim) async {
    setState(() => _claiming = claim.id);
    try {
      await for (final message in tariOotle!.claimBurn(widget.wallet, claim.id)) {
        if (mounted) setState(() => _progress[claim.id] = message);
      }
    } catch (e) {
      if (mounted) setState(() => _progress[claim.id] = _message(e));
    }
    if (!mounted) return;
    setState(() => _claiming = null);
    await _load();
  }

  static String _message(Object e) {
    final text = e.toString();
    // flutter_rust_bridge wraps Rust errors as "AnyhowException(<message>)".
    final match = RegExp(r'^\w*Exception\((.*)\)$', dotAll: true).firstMatch(text);
    return match?.group(1) ?? text.replaceFirst('Exception: ', '');
  }

  String _statusLine(TariOotleClaim c) {
    switch (c.status) {
      case 'claimed':
        return 'Claimed';
      case 'submitted':
        return 'Submitted, waiting for the network';
      default:
        final epoch = _epoch;
        return epoch != null && epoch <= c.minedInEpoch
            ? 'Claimable after L2 epoch ${c.minedInEpoch} (now $epoch)'
            : 'Ready to claim';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final key = _claimKey;
    return Material(
      child: Container(
        color: scheme.surface,
        child: SafeArea(
          child: Column(children: [
            ModalTopBar(
              title: 'Claim from L1',
              leadingIcon: Icon(Icons.arrow_back_ios_new),
              leadingSemanticLabel: S.of(context).seed_alert_back,
              onLeadingPressed: Navigator.of(context).pop,
              trailingIcon: Icon(Icons.refresh),
              trailingSemanticLabel: 'Refresh',
              onTrailingPressed: _load,
            ),
            Expanded(
              child: ListView(padding: EdgeInsets.all(16), children: [
                Text('Claim XTM burned on Minotari (L1) to this wallet. A burn can be claimed '
                    'once it has 3 confirmations on L1 and the L2 epoch has passed the epoch it '
                    'was mined in.'),
                SizedBox(height: 8),
                if (key == null)
                  Text('Waiting for the wallet to connect to an indexer.',
                      style: TextStyle(color: scheme.error))
                else ...[
                  if (_epoch != null)
                    Text('Current L2 epoch: $_epoch',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  SizedBox(height: 16),
                  Text('Claims', style: Theme.of(context).textTheme.titleMedium),
                  if (_loading) LinearProgressIndicator(),
                  if (_loadError != null) Text(_loadError!, style: TextStyle(color: scheme.error)),
                  if (!_loading && _claims.isEmpty && _loadError == null)
                    Text('No burns found for this wallet yet.',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  for (final claim in _claims) _claimCard(claim, scheme),
                  for (final entry in _importErrors.entries)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Could not add ${entry.key}: ${entry.value}',
                          style: TextStyle(color: scheme.error)),
                    ),
                  SizedBox(height: 24),
                  Text('Add a proof', style: Theme.of(context).textTheme.titleMedium),
                  Text('Paste a burn proof JSON from Tari Universe or minotari-cli.',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  TextField(
                    key: ValueKey('tari_claim_paste'),
                    controller: _pasted,
                    minLines: 2,
                    maxLines: 6,
                    decoration: InputDecoration(hintText: '{"claim_proof": ...}'),
                  ),
                  if (_pasteError != null)
                    Text(_pasteError!, style: TextStyle(color: scheme.error)),
                  SizedBox(height: 8),
                  NewPrimaryButton(
                    onPressed: _addPasted,
                    text: 'Add proof',
                    color: scheme.surfaceContainer,
                    textColor: scheme.primary,
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _claimCard(TariOotleClaim claim, ColorScheme scheme) {
    final progress = _progress[claim.id];
    return Card(
      margin: EdgeInsets.only(top: 8),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
          Text(claim.amount.toStringWithSymbol(fractionalDigits: 6, trimZeros: false),
              style: Theme.of(context).textTheme.titleMedium),
          Text(_statusLine(claim)),
          Text('Mined in L2 epoch ${claim.minedInEpoch}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          if (claim.txId != null)
            Text('Transaction ${claim.txId}', style: TextStyle(color: scheme.onSurfaceVariant)),
          if (claim.lastError != null)
            Text('Last attempt: ${claim.lastError}', style: TextStyle(color: scheme.error)),
          if (progress != null) Text(progress),
          if (claim.status != 'claimed')
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: NewPrimaryButton(
                onPressed: () => _claim(claim),
                text: 'Claim',
                color: scheme.primary,
                textColor: scheme.onPrimary,
                isLoading: _claiming == claim.id,
                disabled: _claiming != null,
              ),
            ),
        ]),
      ),
    );
  }
}
